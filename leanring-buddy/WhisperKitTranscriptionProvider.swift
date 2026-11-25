//
//  WhisperKitTranscriptionProvider.swift
//  leanring-buddy
//
//  WhisperKit (base.en on ANE) streaming ASR behind
//  BuddyTranscriptionProvider. Qualified 2026-06-08: ~1s warm load,
//  ~9x realtime. Per-capture local vocabulary conditions partial and final
//  decoding without forcing transcript prefixes.
//
//  Streaming strategy: push-to-talk utterances are short (seconds, not
//  minutes), so the session accumulates 16 kHz mono samples and
//  re-transcribes the WHOLE buffer on a ~1.2s cadence for live partials,
//  then runs one final pass when the user releases the key. Simpler and
//  more robust than incremental windowing at these lengths; revisit if
//  PTT ever allows >60s holds.
//

import AVFoundation
import Foundation
// `@preconcurrency` silences Sendable-conformance warnings for WhisperKit's
// own types (the module predates strict concurrency). The runtime behavior is
// unchanged — the provider still fails fast to Apple Speech when the model is
// missing, and the `WhisperKit` value is only ever touched inside the actor
// that loads it.
@preconcurrency import WhisperKit

struct WhisperKitTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class WhisperKitTranscriptionProvider: BuddyTranscriptionProvider {
    static let isRuntimeAvailable = true

    /// Small English model provisioned by setup-whisperkit.py. `download: false`
    /// keeps Pace zero-network even on a misconfigured machine — a missing
    /// model is a thrown error, never a silent download.
    nonisolated static let modelName = "openai_whisper-base.en"
    nonisolated static var modelFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pace/Models/WhisperKit")
            .appendingPathComponent(modelName)
    }

    nonisolated enum LanguageMode: Equatable, Sendable {
        case english, automaticJapaneseEnglish

        var modelName: String { self == .english ? "openai_whisper-base.en" : "openai_whisper-base" }
        var decodingLanguage: String? { self == .english ? "en" : nil }
        var detectsLanguage: Bool { self == .automaticJapaneseEnglish }
        var modelFolderURL: URL {
            WhisperKitTranscriptionProvider.modelFolderURL.deletingLastPathComponent().appendingPathComponent(modelName)
        }
    }

    let languageMode: LanguageMode
    var displayName: String { languageMode == .english ? "WhisperKit" : "WhisperKit · Japanese / English" }

    init(languageMode: LanguageMode = .english) { self.languageMode = languageMode }
    let requiresSpeechRecognitionPermission = false

    // One pipeline per app lifetime (~146 MB of CoreML assets); concurrent
    // first-callers await the same load.
    private static let runtime = WhisperKitRuntimeCache(languageMode: .english)
    private static let multilingualRuntime = WhisperKitRuntimeCache(languageMode: .automaticJapaneseEnglish)
    private var runtime: WhisperKitRuntimeCache {
        languageMode == .english ? Self.runtime : Self.multilingualRuntime
    }

    func startStreamingSession(
        contextualPhrases: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let pipeline = try await runtime.pipeline()
        return WhisperKitStreamingSession(
            pipeline: pipeline,
            languageMode: languageMode,
            contextualPromptTokens: Self.contextualPromptTokens(
                contextualPhrases,
                encode: pipeline.tokenizer.map { tokenizer in { tokenizer.encode(text: $0) } },
                specialTokenBegin: pipeline.tokenizer?.specialTokens.specialTokenBegin ?? 0),
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    nonisolated static func contextualPromptTokens(
        _ phrases: [String], encode: ((String) -> [Int])?, specialTokenBegin: Int
    ) -> [Int] {
        guard let encode else { return [] }
        let vocabulary = phrases.prefix(80).map { String($0.prefix(80)) }.joined(separator: ", ")
        guard !vocabulary.isEmpty else { return [] }
        return Array(
            encode(" " + vocabulary).filter { $0 >= 0 && $0 < specialTokenBegin }.prefix(
                max(0, (Constants.maxTokenContext / 2) - 1)))
    }

    nonisolated static func decodingOptions(languageMode: LanguageMode, contextualPromptTokens: [Int] = [])
        -> DecodingOptions
    {
        var options = DecodingOptions()
        options.language = languageMode.decodingLanguage
        options.detectLanguage = languageMode.detectsLanguage
        options.temperature = 0
        if !contextualPromptTokens.isEmpty {
            options.promptTokens = contextualPromptTokens
            options.usePrefillPrompt = true
        }
        return options
    }

    nonisolated static func decodeFinalCapture(
        _ audio: [Float], options: DecodingOptions,
        containsSpeech: ([Float]) throws -> Bool,
        confirmsAmplifiedSpeech: ([Float]) throws -> Bool,
        decode: ([Float], DecodingOptions) async throws -> String
    ) async throws -> String {
        guard !audio.isEmpty else { return "" }
        try Task.checkCancellation()
        let speechAudio: [Float]
        if try containsSpeech(audio) {
            speechAudio = audio
        } else {
            // A low input level can hide speech from the detector. Recheck
            // with bounded gain before letting the decoder see the audio.
            let peak = audio.reduce(Float(0)) { max($0, abs($1)) }
            guard peak >= 0.001, peak < 0.12 else { return "" }
            let gain = min(8, 0.12 / peak)
            let amplifiedAudio = audio.map { $0 * gain }
            guard try confirmsAmplifiedSpeech(amplifiedAudio) else { return "" }
            speechAudio = amplifiedAudio
        }
        try Task.checkCancellation()
        let transcript = try await decode(speechAudio, options)
        guard transcript.isEmpty, options.promptTokens?.isEmpty == false else { return transcript }
        try Task.checkCancellation()
        // Keep Whisper's own no-speech threshold. Retry only without the
        // optional vocabulary that can bias a weak first decode.
        var unbiasedOptions = options
        unbiasedOptions.promptTokens = nil
        return try await decode(speechAudio, unbiasedOptions)
    }

    func prepare() async throws { _ = try await runtime.pipeline() }

    func transcribeAudioFile(_ fileURL: URL) async throws -> String {
        let pipeline = try await runtime.pipeline()
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: fileURL.path)
        return try await WhisperKitStreamingSession.transcribe(samples, pipeline: pipeline, languageMode: languageMode)
    }

    func warmUpModelInBackground(onReady: @escaping @Sendable @MainActor () -> Void) {
        let runtime = runtime
        Task.detached(priority: .utility) {
            // Best-effort: a failed warm-up surfaces as a thrown error on the
            // first real session instead.
            _ = try? await runtime.pipeline()
            await MainActor.run { onReady() }
        }
    }
}

/// Transfer box for the non-Sendable `WhisperKit` pipeline. WhisperKit predates
/// strict concurrency and isn't `Sendable`, but Pace constructs exactly one
/// instance, hands it to a single streaming session, and never mutates it from
/// two threads at once — so transferring the constructed value across an
/// isolation boundary is safe in practice. The `@unchecked Sendable` box makes
/// that contract explicit and lets the load `Task` carry a Sendable Success
/// type so no raw non-Sendable value crosses the boundary.
private struct WhisperKitBox: @unchecked Sendable {
    let pipeline: WhisperKit
}

/// Serializes WhisperKit construction so the model loads exactly once.
///
/// Intentionally a `nonisolated` class rather than an `actor`: keeping the
/// cache nonisolated and boxing the result means the `WhisperKit` value never
/// crosses an isolation boundary unboxed. A plain `NSLock` guards the single
/// shared load `Task`, which is what serialized concurrent first-callers before
/// — same behavior, no boundary crossing.
private final class WhisperKitRuntimeCache: @unchecked Sendable {
    private let languageMode: WhisperKitTranscriptionProvider.LanguageMode
    init(languageMode: WhisperKitTranscriptionProvider.LanguageMode) { self.languageMode = languageMode }
    private let loadTaskLock = NSLock()
    private var loadTask: Task<WhisperKitBox, Error>?

    func pipeline() async throws -> WhisperKit {
        let task = loadTaskLock.withLock { () -> Task<WhisperKitBox, Error> in
            if let existingLoadTask = loadTask {
                return existingLoadTask
            }
            let newLoadTask = Task<WhisperKitBox, Error> {
                let folder = self.languageMode.modelFolderURL
                guard FileManager.default.fileExists(atPath: folder.path) else {
                    throw WhisperKitTranscriptionProviderError(
                        message:
                            "WhisperKit model not found at \(folder.path). Run python3 scripts/setup-whisperkit.py\(self.languageMode == .automaticJapaneseEnglish ? " --multilingual" : "")."
                    )
                }
                let config = WhisperKitConfig(
                    model: self.languageMode.modelName,
                    modelFolder: folder.path,
                    download: false
                )
                return WhisperKitBox(pipeline: try await WhisperKit(config))
            }
            loadTask = newLoadTask
            return newLoadTask
        }

        do {
            return try await task.value.pipeline
        } catch {
            // Allow a retry after transient failures (e.g. first-launch
            // CoreML compile interrupted) instead of caching the error.
            loadTaskLock.withLock {
                // Only clear if this failed task is still the cached one, so a
                // concurrent successful reload isn't accidentally discarded.
                if loadTask == task {
                    loadTask = nil
                }
            }
            throw error
        }
    }
}

private final class WhisperKitStreamingSession: BuddyStreamingTranscriptionSession {
    /// Leave time for a second decode when the first returns no words.
    /// CompanionManager's independent 12-second watchdog still bounds waiting.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 8

    private static let targetSampleRate = 16_000.0
    private static let partialCadenceSeconds = 1.2

    private let pipeline: WhisperKit
    private let decodingOptions: DecodingOptions
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    // Audio arrives on the capture thread; transcription runs on Tasks.
    private let sampleLock = NSLock()
    private var samples: [Float] = []
    private var finalRequested = false

    private var partialTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var isTranscribing = false
    private var lastPartialAt = Date.distantPast

    init(
        pipeline: WhisperKit,
        languageMode: WhisperKitTranscriptionProvider.LanguageMode,
        contextualPromptTokens: [Int],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.pipeline = pipeline
        self.decodingOptions = WhisperKitTranscriptionProvider.decodingOptions(
            languageMode: languageMode,
            contextualPromptTokens: contextualPromptTokens)
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard
            let resampled = AudioProcessor.resampleAudio(
                fromBuffer: audioBuffer,
                toSampleRate: Self.targetSampleRate,
                channelCount: 1
            ), let channel = resampled.floatChannelData
        else {
            return  // drop unconvertible buffers; next buffer recovers
        }
        let frameCount = Int(resampled.frameLength)
        let incoming = Array(UnsafeBufferPointer(start: channel[0], count: frameCount))

        sampleLock.lock()
        guard !finalRequested else {
            sampleLock.unlock()
            return
        }
        samples.append(contentsOf: incoming)
        sampleLock.unlock()

        schedulePartialIfDue()
    }

    func requestFinalTranscript() {
        sampleLock.lock()
        guard !finalRequested else {
            sampleLock.unlock()
            return
        }
        finalRequested = true
        let snapshot = samples
        sampleLock.unlock()
        partialTask?.cancel()

        finalTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.transcribeFinalCapture(snapshot)
                try Task.checkCancellation()
                self.onFinalTranscriptReady(text)
            } catch {
                if !Task.isCancelled { self.onError(error) }
            }
        }
    }

    func cancel() {
        sampleLock.lock()
        finalRequested = true
        samples.removeAll()
        sampleLock.unlock()
        partialTask?.cancel()
        finalTask?.cancel()
    }

    private func schedulePartialIfDue() {
        guard Date().timeIntervalSince(lastPartialAt) >= Self.partialCadenceSeconds,
            !isTranscribing
        else { return }
        lastPartialAt = Date()
        isTranscribing = true

        sampleLock.lock()
        let snapshot = samples
        let cancelled = finalRequested
        sampleLock.unlock()
        guard !cancelled, !snapshot.isEmpty else {
            isTranscribing = false
            return
        }

        partialTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isTranscribing = false }
            do {
                let text = try await self.transcribe(snapshot)
                if !Task.isCancelled, !text.isEmpty {
                    self.onTranscriptUpdate(text)
                }
            } catch {
                // Partial failures are non-fatal — the final pass decides.
            }
        }
    }

    private func transcribeFinalCapture(_ audio: [Float]) async throws -> String {
        let startedAt = Date()
        let transcript = try await WhisperKitTranscriptionProvider.decodeFinalCapture(
            audio, options: decodingOptions,
            containsSpeech: { try PaceSileroSpeechDetector.containsSpeech(in: $0) },
            confirmsAmplifiedSpeech: {
                try PaceSileroSpeechDetector.containsSpeech(
                    in: $0, minimumProbability: 0.6,
                    minimumConsecutiveFrames: 3)
            },
            decode: { [pipeline] acceptedAudio, options in
                try await Self.decode(acceptedAudio, pipeline: pipeline, options: options)
            }
        )
        if !Task.isCancelled {
            PaceAPIAuditLog.shared.record(
                subsystem: "dictation", operation: "whisper_final_decode",
                target: "WhisperKit", durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1000),
                outcome: transcript.isEmpty ? "empty" : "recognized")
        }
        return transcript
    }

    private func transcribe(_ audio: [Float]) async throws -> String {
        try await Self.transcribe(audio, pipeline: pipeline, decodingOptions: decodingOptions)
    }

    static func transcribe(
        _ audio: [Float], pipeline: WhisperKit,
        languageMode: WhisperKitTranscriptionProvider.LanguageMode
    ) async throws -> String {
        try await transcribe(
            audio, pipeline: pipeline,
            decodingOptions: WhisperKitTranscriptionProvider.decodingOptions(languageMode: languageMode))
    }

    private static func transcribe(_ audio: [Float], pipeline: WhisperKit, decodingOptions: DecodingOptions)
        async throws -> String
    {
        guard !audio.isEmpty else { return "" }
        guard try PaceSileroSpeechDetector.containsSpeech(in: audio) else { return "" }
        return try await decode(audio, pipeline: pipeline, options: decodingOptions)
    }

    private static func decode(_ audio: [Float], pipeline: WhisperKit, options: DecodingOptions) async throws -> String
    {
        let results = try await pipeline.transcribe(audioArray: audio, decodeOptions: options)
        return results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
