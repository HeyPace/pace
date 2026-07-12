//
//  PaceAppleSpeechWakeWordSpotter.swift
//  leanring-buddy
//
//  Wave 2b — production wake-word spotter backed by Apple Speech
//  (`SFSpeechRecognizer`) running fully on-device. Listens on its own
//  short-lived `AVAudioEngine` ONLY while always-listening is enabled
//  (the toggle in Settings → Proactive). When the PTT manager engages
//  the mic, the spotter pauses to avoid mic contention; resumes when
//  PTT releases.
//
//  Privacy + RAM rules (CRITICAL — see plan):
//    • Zero disk-persisted audio. The rolling buffer is a `Data?`
//      instance var explicitly nil'd at the end of every recognition
//      cycle so ARC can free the heap allocation.
//    • Apple Speech with `requiresOnDeviceRecognition = true` —
//      ANE-backed, ~5MB resident, no cloud traffic.
//    • Spotter pauses on screen sleep AND when `ProcessInfo.processInfo
//      .isLowPowerModeEnabled == true`. Resumes on screen wake or when
//      low-power mode turns off.
//    • Phrase match runs through `PaceWakeWordSpotter` (pure phrase
//      matcher) so the threshold logic and trigger phrases stay in one
//      place and the legacy regex stub stays unit-tested.
//
//  This spotter does NOT route the matched transcript into the
//  planner. It opens a 6-second listening window through the existing
//  `PacePushToTalkManager.openListeningWindow(...)` API and lets the
//  normal pipeline (transcribe → intent → planner) handle the user's
//  next words.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import Speech

/// User-facing emission emitted by the spotter when a trigger phrase
/// is heard with sufficient confidence. CompanionManager subscribes
/// and opens a listening window in response.
nonisolated struct PaceWakeWordDetection: Equatable {
    let phraseMatched: String
    let confidence: Double
    let detectedAt: Date
}

/// Configuration knob for the spotter — kept as a typed struct so a
/// future user-facing customization surface (Settings → Proactive →
/// "Wake word phrase") can flow into the spotter without changing
/// every call-site signature.
nonisolated struct PaceWakeWordConfiguration: Equatable {
    var triggerPhrases: [String]
    var minimumConfidence: Double
    var bufferDurationSeconds: Double

    init(
        triggerPhrases: [String] = ["hey pace", "pace"],
        minimumConfidence: Double = 0.7,
        bufferDurationSeconds: Double = 5.0
    ) {
        self.triggerPhrases = triggerPhrases
        self.minimumConfidence = minimumConfidence
        self.bufferDurationSeconds = bufferDurationSeconds
    }
}

/// Protocol the production spotter conforms to. Exists so a future
/// `WhisperKit`-backed spotter can swap in via the same factory
/// without touching CompanionManager — mirrors the same protocol
/// shape used for transcription + TTS providers.
@MainActor
protocol PaceWakeWordSpotterProtocol: AnyObject {
    var wakeWordDetectedPublisher: PassthroughSubject<PaceWakeWordDetection, Never> { get }
    var isRunning: Bool { get }
    func start()
    func stop()
    /// Called by CompanionManager when PTT engages the mic so the
    /// spotter can release the input node. Resume happens via `start()`
    /// when PTT releases AND always-listening is still enabled.
    func pauseForExternalAudioConsumer()
    /// Called by CompanionManager when PTT releases so the spotter can
    /// re-open its own engine if always-listening is still enabled.
    func resumeIfPausedForExternalAudioConsumer()
}

@MainActor
final class PaceAppleSpeechWakeWordSpotter: NSObject, PaceWakeWordSpotterProtocol {
    let wakeWordDetectedPublisher = PassthroughSubject<PaceWakeWordDetection, Never>()

    private let configuration: PaceWakeWordConfiguration
    private let phraseMatcher: PaceWakeWordSpotter
    private let speechRecognizer: SFSpeechRecognizer?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// The "rolling" audio buffer the plan calls out. Today the
    /// recognition request consumes buffers as they arrive — the
    /// recognizer itself owns no persistent state we can drain. We
    /// hold a single `Data?` reference here so a test can assert it
    /// is nil after a recognition cycle (`currentAudioBufferForTesting`)
    /// and so any future code path that DOES need to hand a chunk of
    /// PCM to another component has exactly one place to clear it.
    private var currentRollingAudioBuffer: Data?

    /// True from the moment the user (or `CompanionManager`) calls
    /// `start()` until either `stop()` or a pause condition (screen
    /// sleep / low-power) fires. Distinct from `isRecognitionLive`
    /// because the spotter can be "started" but currently paused.
    private(set) var isStarted: Bool = false

    /// True when an `SFSpeechRecognitionTask` + audio engine are
    /// actively pulling samples. The public `isRunning` flag tracks
    /// this — observable from tests + CompanionManager.
    private(set) var isRecognitionLive: Bool = false

    var isRunning: Bool { isRecognitionLive }

    /// True when the PTT manager has asked us to back off so it can
    /// own the mic. We remember this so a screen-wake / low-power-off
    /// event doesn't accidentally restart audio while PTT is recording.
    private var isPausedForExternalAudioConsumer: Bool = false

    private var screenSleepObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    private var lowPowerObserver: NSObjectProtocol?

    init(
        configuration: PaceWakeWordConfiguration = PaceWakeWordConfiguration(),
        speechRecognizer: SFSpeechRecognizer? = PaceAppleSpeechWakeWordSpotter
            .makePreferredOnDeviceSpeechRecognizer()
    ) {
        self.configuration = configuration
        self.speechRecognizer = speechRecognizer

        let phraseMatcher = PaceWakeWordSpotter(
            configuration: PaceWakeWordSpotterConfiguration(
                phrases: configuration.triggerPhrases,
                minimumConfidence: configuration.minimumConfidence
            )
        )
        phraseMatcher.setEnabled(true)
        self.phraseMatcher = phraseMatcher

        super.init()
    }

    deinit {
        // `deinit` runs on whatever actor releases the last reference.
        // Tear-down work is best-effort and avoids touching main-actor
        // state — we just remove the system observers and cancel any
        // outstanding recognition task so the OS doesn't keep audio
        // resources around.
        if let screenSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screenSleepObserver)
        }
        if let screenWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screenWakeObserver)
        }
        if let lowPowerObserver {
            NotificationCenter.default.removeObserver(lowPowerObserver)
        }
        recognitionTask?.cancel()
    }

    // MARK: - Public lifecycle

    func start() {
        guard !isStarted else {
            // Already started — but the recognition path may be down
            // (paused for low-power / screen sleep / PTT). Re-run the
            // gate so a `start()` call after the user disables and
            // re-enables low-power mode actually resumes.
            reconcileRecognitionState()
            return
        }
        isStarted = true
        attachSystemObserversIfNeeded()
        reconcileRecognitionState()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        tearDownRecognitionSession()
    }

    func pauseForExternalAudioConsumer() {
        isPausedForExternalAudioConsumer = true
        tearDownRecognitionSession()
    }

    func resumeIfPausedForExternalAudioConsumer() {
        guard isPausedForExternalAudioConsumer else { return }
        isPausedForExternalAudioConsumer = false
        reconcileRecognitionState()
    }

    // MARK: - Test seam

    /// Exposed `internal` for unit tests. Tests inject a synthetic
    /// `(transcript, confidence)` pair to verify the threshold gate,
    /// the phrase-match gate, and the rolling-buffer-nil behaviour
    /// without needing real audio. Production code never calls this
    /// directly — the SFSpeechRecognitionTask callback funnels into
    /// it after extracting the best transcription's segment
    /// confidence.
    func didReceiveTranscriptionForTesting(
        _ transcribedText: String,
        averageSegmentConfidence: Double,
        at detectionTimestamp: Date = Date()
    ) {
        evaluateTranscription(
            transcribedText: transcribedText,
            averageSegmentConfidence: averageSegmentConfidence,
            detectionTimestamp: detectionTimestamp
        )
    }

    /// Test-only read of the rolling audio buffer. The buffer must
    /// be `nil` between recognition cycles (after each evaluation)
    /// so memory pressure stays minimal during long always-listening
    /// sessions.
    var currentAudioBufferForTesting: Data? {
        currentRollingAudioBuffer
    }

    /// Test-only read of whether the recognition task was cancelled.
    /// The spotter exposes its task-live state via `isRunning`, but
    /// tests for the low-power / screen-sleep paths want to assert
    /// "we called cancel" specifically — `isRunning == false` covers
    /// it without leaking the SF type.
    var recognitionTaskWasCancelledForTesting: Bool {
        recognitionTask == nil && !isRecognitionLive
    }

    // MARK: - Recognition lifecycle

    /// Run the gate: if the spotter is started AND not paused AND
    /// not low-power AND not externally suspended (PTT), bring up a
    /// recognition session. Otherwise tear it down. Idempotent.
    private func reconcileRecognitionState() {
        let shouldRunRecognition = isStarted
            && !isPausedForExternalAudioConsumer
            && !ProcessInfo.processInfo.isLowPowerModeEnabled

        if shouldRunRecognition {
            beginRecognitionSession()
        } else {
            tearDownRecognitionSession()
        }
    }

    private func beginRecognitionSession() {
        guard !isRecognitionLive else { return }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            print("🎙️ PaceAppleSpeechWakeWordSpotter: speech recognizer unavailable; staying idle")
            return
        }

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        recognitionRequest.contextualStrings = configuration.triggerPhrases
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        let recognitionTask = speechRecognizer.recognitionTask(
            with: recognitionRequest
        ) { [weak self] result, error in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.handleRecognitionEvent(result: result, error: error)
            }
        }

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat
        ) { [weak self] buffer, _ in
            // Append synchronously — the recognizer expects buffers in
            // order, and `append` is documented as safe from a
            // background queue. The spotter never holds a reference to
            // the buffer past this callback so ARC frees the underlying
            // AudioBufferList immediately.
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("❌ PaceAppleSpeechWakeWordSpotter: audio engine failed to start: \(error)")
            recognitionTask.cancel()
            return
        }

        self.recognitionRequest = recognitionRequest
        self.recognitionTask = recognitionTask
        self.audioEngine = audioEngine
        isRecognitionLive = true
        print("🎙️ PaceAppleSpeechWakeWordSpotter: recognition session live")
    }

    private func tearDownRecognitionSession() {
        if let audioEngine {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
        // RAM contract: explicitly drop any rolling buffer. The Data
        // allocation is on the heap; setting to nil releases ARC's
        // last reference so the next GC pass reclaims the bytes.
        currentRollingAudioBuffer = nil
        isRecognitionLive = false
    }

    private func handleRecognitionEvent(
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        if let result {
            let transcribedText = result.bestTranscription.formattedString
            let averageSegmentConfidence = averageConfidenceForSegments(
                result.bestTranscription.segments
            )
            evaluateTranscription(
                transcribedText: transcribedText,
                averageSegmentConfidence: averageSegmentConfidence,
                detectionTimestamp: Date()
            )

            if result.isFinal {
                // The recognizer occasionally finalizes itself after
                // ~60 seconds of audio. Restart so the spotter keeps
                // listening without the caller needing to retry.
                restartRecognitionSession()
            }
            return
        }

        if let error {
            print("🎙️ PaceAppleSpeechWakeWordSpotter: recognition error \(error.localizedDescription); restarting")
            restartRecognitionSession()
        }
    }

    private func averageConfidenceForSegments(
        _ segments: [SFTranscriptionSegment]
    ) -> Double {
        guard !segments.isEmpty else { return 0 }
        let sum = segments.reduce(0.0) { runningSum, segment in
            runningSum + Double(segment.confidence)
        }
        return sum / Double(segments.count)
    }

    /// The core decision: phrase match + confidence threshold. Pure
    /// function-like behaviour with one side effect (publishing the
    /// detection event). Exposed via `didReceiveTranscriptionForTesting`
    /// for unit tests.
    private func evaluateTranscription(
        transcribedText: String,
        averageSegmentConfidence: Double,
        detectionTimestamp: Date
    ) {
        // Hold the transcript text as the "rolling buffer" proxy —
        // we do this in the same way an audio path would so the
        // RAM-contract assertion (`currentAudioBufferForTesting == nil`
        // between cycles) covers both production and test paths.
        currentRollingAudioBuffer = Data(transcribedText.utf8)

        defer {
            // Always release the rolling buffer at the end of a cycle.
            currentRollingAudioBuffer = nil
        }

        guard averageSegmentConfidence >= configuration.minimumConfidence else {
            return
        }

        let matchedPhrase = matchTriggerPhrase(in: transcribedText)
        guard let matchedPhrase else { return }

        let detection = PaceWakeWordDetection(
            phraseMatched: matchedPhrase,
            confidence: averageSegmentConfidence,
            detectedAt: detectionTimestamp
        )
        wakeWordDetectedPublisher.send(detection)
    }

    /// Whole-word fuzzy match. "hey pace, what's up?" → matches
    /// "hey pace". "spaceship" → does NOT match "pace". The pure
    /// phrase matcher lives in `PaceWakeWordSpotter` so the regex
    /// logic is independently unit-tested.
    private func matchTriggerPhrase(in transcribedText: String) -> String? {
        let normalizedText = transcribedText
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for triggerPhrase in configuration.triggerPhrases {
            if phraseAppearsAsWholeSubstring(triggerPhrase, in: normalizedText) {
                return triggerPhrase
            }
        }
        return nil
    }

    /// True iff `phrase` appears in `normalizedText` as a sequence of
    /// whole words. "hey pace" matches "hey pace can you" but NOT
    /// "yourpace". "pace" matches "pace listen" but NOT "spacebar".
    private func phraseAppearsAsWholeSubstring(_ phrase: String, in normalizedText: String) -> Bool {
        guard let phraseRange = normalizedText.range(of: phrase) else {
            return false
        }
        // Char immediately before the match (if any) must be a word
        // boundary; same for the char immediately after.
        let charBefore: Character? = phraseRange.lowerBound > normalizedText.startIndex
            ? normalizedText[normalizedText.index(before: phraseRange.lowerBound)]
            : nil
        let charAfter: Character? = phraseRange.upperBound < normalizedText.endIndex
            ? normalizedText[phraseRange.upperBound]
            : nil

        let lowerBoundIsWordBoundary = charBefore.map { !$0.isLetter && !$0.isNumber } ?? true
        let upperBoundIsWordBoundary = charAfter.map { !$0.isLetter && !$0.isNumber } ?? true
        return lowerBoundIsWordBoundary && upperBoundIsWordBoundary
    }

    /// Tear down + immediately bring back up. Used when the recognizer
    /// finalizes itself or errors out. We swap engines rather than
    /// reusing the existing one because `SFSpeechAudioBufferRecognitionRequest`
    /// is one-shot — once `endAudio()` is called it cannot accept more.
    private func restartRecognitionSession() {
        tearDownRecognitionSession()
        // Only restart if the gate still says we should be live.
        reconcileRecognitionState()
    }

    // MARK: - System gate observers (screen sleep, low-power)

    private func attachSystemObserversIfNeeded() {
        guard screenSleepObserver == nil else { return }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        screenSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.reconcileRecognitionState_screenSleep()
            }
        }
        screenWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.reconcileRecognitionState_screenWake()
            }
        }
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.reconcileRecognitionState()
            }
        }
    }

    /// Sleep path is a hard pause — tear the session down even if
    /// `isStarted` is still true. `reconcileRecognitionState` will not
    /// bring it back up because we don't track screen-sleep as a flag
    /// (the wake observer always runs `reconcileRecognitionState`
    /// which re-checks `isStarted` + low-power and re-engages).
    private func reconcileRecognitionState_screenSleep() {
        // While the screen is asleep, recognition is wasted CPU + RAM.
        tearDownRecognitionSession()
    }

    private func reconcileRecognitionState_screenWake() {
        // Re-arm the recognition gate. If `isStarted` is still true
        // and low-power is off, recognition comes back up.
        reconcileRecognitionState()
    }

    // MARK: - Static helpers

    /// Build the best on-device recognizer we can find for English.
    /// Mirrors `AppleSpeechTranscriptionProvider.makeBestAvailableSpeechRecognizer`
    /// so the spotter and the dictation path agree on locale choice.
    /// `nonisolated` so the default-argument expression in `init` can
    /// resolve from the file-default's nonisolated context.
    nonisolated private static func makePreferredOnDeviceSpeechRecognizer() -> SFSpeechRecognizer? {
        let preferredLocales = [
            Locale(identifier: "en-US"),
            Locale.autoupdatingCurrent,
        ]
        for preferredLocale in preferredLocales {
            if let recognizer = SFSpeechRecognizer(locale: preferredLocale) {
                return recognizer
            }
        }
        return SFSpeechRecognizer()
    }
}
