//
//  LocalTTSClient.swift
//  leanring-buddy
//
//  On-device TTS via Apple's AVSpeechSynthesizer. No network calls,
//  free, private, and offline. The sole BuddyTTSClient conformer
//  today — install a Premium English voice (System Settings →
//  Accessibility → Spoken Content → System Voice → Manage Voices) for
//  the best quality.
//

import AVFoundation
import Foundation

@MainActor
protocol LocalTTSSpeechSynthesizing: AnyObject {
    var delegate: (any AVSpeechSynthesizerDelegate)? { get set }
    var isSpeaking: Bool { get }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: LocalTTSSpeechSynthesizing {}

enum LocalTTSPlaybackError: Error, LocalizedError, Equatable {
    case playbackDidNotStart
    case playbackCancelled

    var errorDescription: String? {
        switch self {
        case .playbackDidNotStart:
            return "Local speech playback did not start. Please try again."
        case .playbackCancelled:
            return "Local speech playback stopped unexpectedly. Please try again."
        }
    }
}

@MainActor
final class LocalTTSClient: NSObject, BuddyTTSClient {
    private let speechSynthesizer: any LocalTTSSpeechSynthesizing
    private let playbackStartTimeout: TimeInterval
    private let auditLog: PaceAPIAuditLog
    private var pendingUtterances: [PendingUtterance] = []
    private var playbackStartTimeoutTask: Task<Void, Never>?
    private var watchedUtteranceIdentifier: ObjectIdentifier?
    static let defaultPlaybackStartTimeout: TimeInterval = 3
    var onPlaybackFailure: (() -> Void)?

    private final class PendingUtterance {
        let utterance: AVSpeechUtterance
        let submittedAt = Date()
        var hasStarted = false
        var startupContinuation: CheckedContinuation<Void, Error>?

        init(utterance: AVSpeechUtterance, startupContinuation: CheckedContinuation<Void, Error>?) {
            self.utterance = utterance
            self.startupContinuation = startupContinuation
        }
    }

    /// The voice identifier to use. Defaults to the system "enhanced" or
    /// "premium" English voice when available, which is markedly better
    /// than the legacy compact voice.
    private let preferredVoiceIdentifier: String?
    private let speechProsody: LocalTTSProsody

    /// Cached `bestAvailableVoice()` result. `AVSpeechSynthesisVoice
    /// .speechVoices()` does a synchronous metadata scan that can take
    /// 50-200ms — calling it on every `speakText()` invocation (which
    /// happens once per sentence-chunk while streaming) shows up as
    /// the "Potential Structural Swift Concurrency Issue: unsafeForcedSync
    /// called from Swift Concurrent context" warning AND as visible
    /// per-chunk jank. Computed once on first use.
    private var memoizedBestVoice: AVSpeechSynthesisVoice?
    private var hasResolvedBestVoice: Bool = false

    private var playbackObserver: LocalTTSPlaybackObserver?

    /// Why playback last ended. Defaults to natural completion; the
    /// streaming pipeline's barge-in path calls
    /// `recordExpectedStopReason(.userBargeIn)` immediately before
    /// `stopPlayback()`, which causes the next stop event to inherit
    /// that reason. Cleared back to natural completion after the
    /// manager has read it, by way of the next successful
    /// `speakText(...)` call that begins a fresh utterance.
    private(set) var lastStopReason: PaceTTSStopReason = .naturalCompletion
    private var pendingNextStopReason: PaceTTSStopReason?

    func recordExpectedStopReason(_ reason: PaceTTSStopReason) {
        pendingNextStopReason = reason
    }

    override convenience init() {
        self.init(speechSynthesizer: AVSpeechSynthesizer())
    }

    init(
        speechSynthesizer: any LocalTTSSpeechSynthesizing,
        playbackStartTimeout: TimeInterval = LocalTTSClient.defaultPlaybackStartTimeout,
        auditLog: PaceAPIAuditLog = .shared
    ) {
        self.speechSynthesizer = speechSynthesizer
        self.playbackStartTimeout = playbackStartTimeout
        self.auditLog = auditLog
        self.preferredVoiceIdentifier = AppBundleConfiguration.stringValue(forKey: "LocalTTSVoiceIdentifier")
        self.speechProsody = LocalTTSProsody.fromBundleConfiguration()
        super.init()

        let observer = LocalTTSPlaybackObserver { [weak self] event, utterance in
            Task { @MainActor in
                self?.handlePlaybackEvent(event, utterance: utterance)
            }
        }
        self.playbackObserver = observer
        self.speechSynthesizer.delegate = observer
    }

    func speakText(_ text: String) async throws {
        try Task.checkCancellation()
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: trimmedText)
        utterance.rate = speechProsody.rate
        utterance.pitchMultiplier = speechProsody.pitchMultiplier
        utterance.volume = speechProsody.volume
        utterance.preUtteranceDelay = speechProsody.preUtteranceDelay
        utterance.postUtteranceDelay = speechProsody.postUtteranceDelay
        let pickedVoice = resolveCachedBestVoice()
        utterance.voice = pickedVoice
        printVoiceUpgradeHintOnceIfCompact(pickedVoice: pickedVoice)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                lastStopReason = .naturalCompletion
                pendingNextStopReason = nil
                // A queued chunk can return immediately only after a delegate
                // confirmed that this queue is already producing speech.
                let hasConfirmedActivePlayback = pendingUtterances.contains { $0.hasStarted }
                    && speechSynthesizer.isSpeaking
                let pendingUtterance = PendingUtterance(
                    utterance: utterance,
                    startupContinuation: hasConfirmedActivePlayback ? nil : continuation
                )
                pendingUtterances.append(pendingUtterance)
                recordPlaybackEvent("submit", pendingUtterance: pendingUtterance)
                speechSynthesizer.speak(utterance)
                schedulePlaybackStartTimeout()
                if hasConfirmedActivePlayback { continuation.resume() }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.pendingUtterances.contains(where: { $0.utterance === utterance }) else { return }
                self.lastStopReason = .manualStop
                self.cancelPendingPlayback(error: CancellationError(), reason: "task_cancelled")
            }
        }
        try Task.checkCancellation()
    }

    private func handlePlaybackEvent(_ event: LocalTTSPlaybackObserver.Event, utterance: AVSpeechUtterance) {
        // stop/new-turn clears the queue before touching the synthesizer.
        // Late callbacks can therefore never mutate a newer queue.
        guard let pendingUtterance = pendingUtterances.first(where: { $0.utterance === utterance }) else { return }
        switch event {
        case .started:
            pendingUtterance.hasStarted = true
            recordPlaybackEvent("start", pendingUtterance: pendingUtterance)
            for queuedUtterance in pendingUtterances {
                queuedUtterance.startupContinuation?.resume()
                queuedUtterance.startupContinuation = nil
            }
        case .finished, .cancelled:
            recordPlaybackEvent(event == .finished ? "finish" : "cancel", pendingUtterance: pendingUtterance)
            // Intentional stops already removed their identities. A native
            // cancellation still in this queue is an unexpected failure.
            // A finish without didStart is not evidence that output began.
            pendingUtterance.startupContinuation?.resume(throwing: event == .cancelled
                ? LocalTTSPlaybackError.playbackCancelled : LocalTTSPlaybackError.playbackDidNotStart)
            pendingUtterance.startupContinuation = nil
            pendingUtterances.removeAll { $0.utterance === utterance }
            if event == .cancelled || !pendingUtterance.hasStarted { onPlaybackFailure?() }
        }
        schedulePlaybackStartTimeout()
    }

    private func schedulePlaybackStartTimeout() {
        guard let nextUtterance = pendingUtterances.first, !nextUtterance.hasStarted else {
            playbackStartTimeoutTask?.cancel()
            playbackStartTimeoutTask = nil
            watchedUtteranceIdentifier = nil
            return
        }
        let utteranceIdentifier = ObjectIdentifier(nextUtterance.utterance)
        guard watchedUtteranceIdentifier != utteranceIdentifier else { return }
        playbackStartTimeoutTask?.cancel()
        watchedUtteranceIdentifier = utteranceIdentifier
        // Only the head of the native queue gets a startup deadline. Later
        // sentences may legitimately wait through a long spoken paragraph.
        playbackStartTimeoutTask = Task { @MainActor [weak self, playbackStartTimeout] in
            do {
                try await Task.sleep(for: .seconds(playbackStartTimeout))
            } catch { return }
            guard let self, let pendingUtterance = self.pendingUtterances.first,
                  ObjectIdentifier(pendingUtterance.utterance) == utteranceIdentifier,
                  !pendingUtterance.hasStarted else { return }
            self.recordPlaybackEvent("timeout", pendingUtterance: pendingUtterance)
            self.lastStopReason = .manualStop
            self.cancelPendingPlayback(error: LocalTTSPlaybackError.playbackDidNotStart, reason: "startup_timeout")
            self.onPlaybackFailure?()
        }
    }

    private func cancelPendingPlayback(error: Error, reason: String) {
        playbackStartTimeoutTask?.cancel()
        playbackStartTimeoutTask = nil
        watchedUtteranceIdentifier = nil
        let cancelledUtterances = pendingUtterances
        pendingUtterances = []
        for pendingUtterance in cancelledUtterances {
            recordPlaybackEvent("cancel", pendingUtterance: pendingUtterance, detail: reason)
            pendingUtterance.startupContinuation?.resume(throwing: error)
            pendingUtterance.startupContinuation = nil
        }
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    private func recordPlaybackEvent(_ event: String, pendingUtterance: PendingUtterance, detail: String? = nil) {
        let utterance = pendingUtterance.utterance
        auditLog.record(
            subsystem: "tts",
            operation: "apple_speech.\(event)",
            target: utterance.voice?.identifier ?? "system_default",
            durationMilliseconds: Int(Date().timeIntervalSince(pendingUtterance.submittedAt) * 1000),
            outcome: event == "finish" && !pendingUtterance.hasStarted ? "not_started" : event,
            inputCharacterCount: utterance.speechString.count,
            detail: "queue=\(pendingUtterances.count);started=\(pendingUtterance.hasStarted);volume=\(utterance.volume);\(detail ?? "")"
        )
    }

    /// Returns the best-available voice, computing it on first call and
    /// caching the result. The `AVSpeechSynthesisVoice.speechVoices()`
    /// scan inside `bestAvailableVoice()` is too expensive to do per
    /// utterance with sentence-level streaming.
    private func resolveCachedBestVoice() -> AVSpeechSynthesisVoice? {
        if hasResolvedBestVoice {
            return memoizedBestVoice
        }
        memoizedBestVoice = bestAvailableVoice()
        hasResolvedBestVoice = true
        return memoizedBestVoice
    }

    var isPlaying: Bool {
        !pendingUtterances.isEmpty
    }

    func stopPlayback() {
        lastStopReason = pendingNextStopReason ?? .manualStop
        pendingNextStopReason = nil
        cancelPendingPlayback(error: CancellationError(), reason: "requested_stop")
    }

    private func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        PaceTTSVoiceResolver.bestAvailableVoice(preferredVoiceIdentifier: preferredVoiceIdentifier)
    }

    /// Prints a one-time, plain-language hint to the Xcode console when
    /// the system is falling back to a compact voice (the default
    /// "Samantha" tier that often sounds shrill / robotic). Users hear
    /// this and assume the app is broken; pointing them at Premium
    /// voices in System Settings fixes it without code change.
    private var hasPrintedVoiceUpgradeHint: Bool = false
    private func printVoiceUpgradeHintOnceIfCompact(pickedVoice: AVSpeechSynthesisVoice?) {
        guard !hasPrintedVoiceUpgradeHint else { return }
        guard let pickedVoice else { return }
        switch pickedVoice.quality {
        case .premium, .enhanced:
            print("🔊 Local TTS voice: \(pickedVoice.name) (\(pickedVoice.quality == .premium ? "Premium" : "Enhanced"))")
        default:
            print("🔊 Local TTS voice: \(pickedVoice.name) (Compact)")
            print("    → For a bigger quality jump, open System Settings → Accessibility → Spoken Content")
            print("      → System Voice → Manage Voices → English (US) and download either:")
            print("        - \"Samantha\" at Enhanced quality (~150 MB, quick stopgap), OR")
            print("        - \"Ava\" at Premium quality (~500 MB, much better neural voice).")
            print("      Restart Pace after the download finishes.")
        }
        hasPrintedVoiceUpgradeHint = true
    }
}

private struct LocalTTSProsody {
    let rate: Float
    let pitchMultiplier: Float
    let volume: Float
    let preUtteranceDelay: TimeInterval
    let postUtteranceDelay: TimeInterval

    static func fromBundleConfiguration() -> LocalTTSProsody {
        // Let high-quality Apple voices use their natural pitch and conversational rate.
        return LocalTTSProsody(
            rate: configuredFloat(
                forKey: "LocalTTSSpeechRate",
                defaultValue: AVSpeechUtteranceDefaultSpeechRate,
                minimumValue: 0.35,
                maximumValue: 0.58
            ),
            pitchMultiplier: configuredFloat(
                forKey: "LocalTTSPitchMultiplier",
                defaultValue: 1.0,
                minimumValue: 0.75,
                maximumValue: 1.15
            ),
            volume: configuredFloat(
                forKey: "LocalTTSVolume",
                defaultValue: 0.94,
                minimumValue: 0.25,
                maximumValue: 1.0
            ),
            preUtteranceDelay: TimeInterval(configuredFloat(
                forKey: "LocalTTSPreUtteranceDelay",
                defaultValue: 0.0,
                minimumValue: 0.0,
                maximumValue: 0.25
            )),
            postUtteranceDelay: TimeInterval(configuredFloat(
                forKey: "LocalTTSPostUtteranceDelay",
                defaultValue: 0.02,
                minimumValue: 0.0,
                maximumValue: 0.25
            ))
        )
    }

    private static func configuredFloat(
        forKey key: String,
        defaultValue: Float,
        minimumValue: Float,
        maximumValue: Float
    ) -> Float {
        guard let configuredStringValue = AppBundleConfiguration.stringValue(forKey: key),
              let configuredFloatValue = Float(configuredStringValue) else {
            return defaultValue
        }

        return min(max(configuredFloatValue, minimumValue), maximumValue)
    }
}

private final class LocalTTSPlaybackObserver: NSObject, AVSpeechSynthesizerDelegate {
    enum Event { case started, finished, cancelled }
    private let onPlaybackEvent: (Event, AVSpeechUtterance) -> Void

    init(onPlaybackEvent: @escaping (Event, AVSpeechUtterance) -> Void) {
        self.onPlaybackEvent = onPlaybackEvent
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onPlaybackEvent(.started, utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onPlaybackEvent(.finished, utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onPlaybackEvent(.cancelled, utterance)
    }
}
