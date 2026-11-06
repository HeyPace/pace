//
//  LocalServerTTSClientTests.swift
//  leanring-buddyTests
//

import AVFoundation
import Foundation
import Testing

@testable import Pace

@MainActor
struct PersistedVoiceSettingsTests {
    private func withPreferences(_ test: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "pace-voice-settings-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        try test(preferences)
    }

    @Test func explicitKokoroSelectionSurvivesReloadingPreferences() {
        let suiteName = "pace-voice-reload-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(" localServer ", forKey: "pace.voice.provider")
        let reloadedPreferences = UserDefaults(suiteName: suiteName)!
        #expect(AppBundleConfiguration.stringValue(forKey: "TTSProvider", preferences: reloadedPreferences) == "localserver")
    }

    @Test func invalidProviderCannotReplaceTheConfiguredFallback() {
        withPreferences { preferences in
            for invalidProvider in ["", " ", "remote", "unsupported"] {
                preferences.set(invalidProvider, forKey: "pace.voice.provider")
                #expect(AppBundleConfiguration.persistedVoiceSetting(forKey: "TTSProvider", preferences: preferences) == nil)
            }
            preferences.set("apple", forKey: "pace.voice.provider")
            #expect(AppBundleConfiguration.persistedVoiceSetting(forKey: "TTSProvider", preferences: preferences) == "apple")
        }
    }

    @Test func voiceOverridesAreTrimmedAndSpeedIsValidated() {
        withPreferences { preferences in
            preferences.set(" af_heart ", forKey: "pace.voice.kokoro.voice")
            #expect(AppBundleConfiguration.persistedVoiceSetting(forKey: "LocalTTSServerVoice", preferences: preferences) == "af_heart")
            for invalidSpeed in ["0", "0.25", "4", "nan", "infinity", "bad"] {
                preferences.set(invalidSpeed, forKey: "pace.voice.kokoro.speed")
                #expect(AppBundleConfiguration.persistedVoiceSetting(forKey: "LocalTTSServerSpeed", preferences: preferences) == nil)
            }
            preferences.set("1.0", forKey: "pace.voice.kokoro.speed")
            #expect(AppBundleConfiguration.persistedVoiceSetting(forKey: "LocalTTSServerSpeed", preferences: preferences) == "1.0")
        }
    }

    @Test func voicePreferencesCannotOverridePrivacyOrProviderEndpoints() {
        withPreferences { preferences in
            for key in ["ReadMyScreen", "EnableActions", "PlannerProvider", "LocalTTSServerBaseURL"] {
                preferences.set("true", forKey: "pace.voice.\(key)")
                #expect(AppBundleConfiguration.persistedVoiceSetting(forKey: key, preferences: preferences) == nil)
            }
        }
    }

    @Test func kokoroSummaryDoesNotClaimAnAppleVoiceIsActive() {
        let summary = PaceTTSVoiceSummary.localServerSummary(voiceIdentifier: "af_heart")
        #expect(summary.displayText == "Heart · Kokoro")
        #expect(!summary.needsUpgrade)
        #expect(summary.recommendationText == "Kokoro speech runs locally on this Mac.")
    }

    @Test func anotherLocalModelIsNotMislabeledAsKokoro() {
        let summary = PaceTTSVoiceSummary.localServerSummary(voiceIdentifier: "Ryan", modelIdentifier: "local-Qwen3-TTS")
        #expect(summary.displayText == "Ryan · Local model")
        #expect(summary.recommendationText == "Speech runs locally on this Mac.")
    }
}

@MainActor
private final class TestSpeechSynthesizer: LocalTTSSpeechSynthesizing {
    var delegate: (any AVSpeechSynthesizerDelegate)?
    var isSpeaking = false
    private(set) var utterances: [AVSpeechUtterance] = []
    private(set) var stopCount = 0
    private let delegateSource = AVSpeechSynthesizer()

    func speak(_ utterance: AVSpeechUtterance) { utterances.append(utterance) }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopCount += 1
        isSpeaking = false
        return true
    }

    func start(_ utterance: AVSpeechUtterance) {
        isSpeaking = true
        delegate?.speechSynthesizer?(delegateSource, didStart: utterance)
    }

    func finish(_ utterance: AVSpeechUtterance) {
        isSpeaking = false
        delegate?.speechSynthesizer?(delegateSource, didFinish: utterance)
    }

    func cancel(_ utterance: AVSpeechUtterance) {
        delegate?.speechSynthesizer?(delegateSource, didCancel: utterance)
    }
}

@MainActor
struct LocalTTSPlaybackStateTests {
    private func makeAuditLog() -> PaceAPIAuditLog {
        PaceAPIAuditLog(logFileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-speech-tests-\(UUID().uuidString).jsonl"))
    }

    private func waitForSubmission(_ synthesizer: TestSpeechSynthesizer, count: Int = 1) async throws {
        for _ in 0..<1_000 {
            if synthesizer.utterances.count >= count { return }
            await Task.yield()
        }
        #expect(synthesizer.utterances.count >= count)
        throw CancellationError()
    }

    @Test func submissionOnlySucceedsAfterDelegateConfirmsPlaybackStarted() async throws {
        let synthesizer = TestSpeechSynthesizer()
        let auditLog = makeAuditLog()
        let client = LocalTTSClient(speechSynthesizer: synthesizer, auditLog: auditLog)
        var submissionReturned = false
        let submission = Task {
            try await client.speakText("A private test sentence.")
            submissionReturned = true
        }
        defer { client.stopPlayback() }
        try await waitForSubmission(synthesizer)
        #expect(client.isPlaying)
        #expect(!submissionReturned)
        synthesizer.start(try #require(synthesizer.utterances.first))
        try await submission.value
        #expect(submissionReturned)
        synthesizer.finish(try #require(synthesizer.utterances.first))
        for _ in 0..<100 { await Task.yield() }
        #expect(!client.isPlaying)
        let entries = auditLog.readAllEntries()
        #expect(entries.map(\.operation) == ["apple_speech.submit", "apple_speech.start", "apple_speech.finish"])
        #expect(entries.allSatisfy { $0.detail?.contains("private test") != true })
    }

    @Test func missingStartThrowsAndAuditsFailureInsteadOfReportingSuccess() async throws {
        let synthesizer = TestSpeechSynthesizer()
        let auditLog = makeAuditLog()
        let client = LocalTTSClient(speechSynthesizer: synthesizer, playbackStartTimeout: 0.02, auditLog: auditLog)
        do {
            try await client.speakText("This never starts.")
            Issue.record("An unstarted utterance must not report successful playback.")
        } catch {
            #expect(error is LocalTTSPlaybackError)
        }
        #expect(!client.isPlaying)
        #expect(synthesizer.stopCount == 1)
        #expect(auditLog.readAllEntries().contains { $0.operation == "apple_speech.timeout" })
    }

    @Test func unexpectedNativeCancellationBeforeStartThrowsPlaybackFailure() async throws {
        let synthesizer = TestSpeechSynthesizer()
        let client = LocalTTSClient(speechSynthesizer: synthesizer, auditLog: makeAuditLog())
        var failureNoticeCount = 0
        let submission = Task {
            try await client.speakText("Native cancellation before playback.", onPlaybackFailure: { failureNoticeCount += 1 })
        }
        try await waitForSubmission(synthesizer)
        synthesizer.cancel(try #require(synthesizer.utterances.first))
        do {
            try await submission.value
            Issue.record("Unexpected native cancellation must fail startup.")
        } catch {
            #expect(error as? LocalTTSPlaybackError == .playbackCancelled)
        }
        #expect(failureNoticeCount == 1)
        #expect(!client.isPlaying)
    }

    @Test func unexpectedNativeCancellationAfterStartReportsVisiblePipelineFailure() async throws {
        let synthesizer = TestSpeechSynthesizer()
        let client = LocalTTSClient(speechSynthesizer: synthesizer, auditLog: makeAuditLog())
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: client)
        var failureNoticeCount = 0
        pipeline.onPlaybackFailure = { failureNoticeCount += 1 }
        let submission = Task { await pipeline.acceptStreamedText("This sentence starts before cancellation.") }
        try await waitForSubmission(synthesizer)
        let utterance = try #require(synthesizer.utterances.first)
        synthesizer.start(utterance)
        await submission.value
        synthesizer.cancel(utterance)
        for _ in 0..<100 { await Task.yield() }
        #expect(failureNoticeCount == 1)
        #expect(!client.isPlaying)
        #expect(pipeline.inFlightStreamedText == "This sentence starts before cancellation.")
    }

    @Test func stopWhilePendingRejectsWaiterAndStaleCallbacksCannotStopFreshSpeech() async throws {
        let synthesizer = TestSpeechSynthesizer()
        let client = LocalTTSClient(speechSynthesizer: synthesizer, auditLog: makeAuditLog())
        var failureNoticeCount = 0
        let oldSubmission = Task {
            try await client.speakText("Old pending sentence.", onPlaybackFailure: { failureNoticeCount += 1 })
        }
        try await waitForSubmission(synthesizer)
        let oldUtterance = try #require(synthesizer.utterances.first)
        client.stopPlayback()
        do {
            try await oldSubmission.value
            Issue.record("Stopping pending playback must reject the waiter.")
        } catch { #expect(error is CancellationError) }
        #expect(!client.isPlaying)

        let freshSubmission = Task { try await client.speakText("Fresh sentence.") }
        defer { client.stopPlayback() }
        try await waitForSubmission(synthesizer, count: 2)
        let freshUtterance = try #require(synthesizer.utterances.last)
        synthesizer.start(freshUtterance)
        try await freshSubmission.value
        synthesizer.cancel(oldUtterance)
        synthesizer.finish(oldUtterance)
        for _ in 0..<100 { await Task.yield() }
        #expect(client.isPlaying)
        #expect(synthesizer.stopCount == 1)
        #expect(failureNoticeCount == 0)
    }

    @Test func queuedChunkDoesNotExpireWhileEarlierSpeechIsActive() async throws {
        let synthesizer = TestSpeechSynthesizer()
        let auditLog = makeAuditLog()
        let client = LocalTTSClient(speechSynthesizer: synthesizer, playbackStartTimeout: 0.03, auditLog: auditLog)
        var failureNoticeCount = 0
        let firstSubmission = Task { try await client.speakText("The first sentence keeps speaking.") }
        defer { client.stopPlayback() }
        try await waitForSubmission(synthesizer)
        let firstUtterance = try #require(synthesizer.utterances.first)
        synthesizer.start(firstUtterance)
        try await firstSubmission.value
        try await client.speakText("This sentence waits in the native queue.", onPlaybackFailure: { failureNoticeCount += 1 })
        try await Task.sleep(for: .milliseconds(70))
        #expect(client.isPlaying)
        #expect(synthesizer.stopCount == 0)
        #expect(!auditLog.readAllEntries().contains { $0.operation == "apple_speech.timeout" })

        // Once the previous sentence ends, a queued chunk that never starts
        // must still be bounded, even though its submission already returned.
        synthesizer.finish(firstUtterance)
        try await Task.sleep(for: .milliseconds(70))
        #expect(!client.isPlaying)
        #expect(synthesizer.stopCount == 1)
        #expect(auditLog.readAllEntries().contains { $0.operation == "apple_speech.timeout" })
        #expect(failureNoticeCount == 1)
    }

    @Test func missingFinishReconcilesConfirmedSpeechAfterNativeBecomesIdleWithoutPolling() async throws {
        let synthesizer = TestSpeechSynthesizer()
        let auditLog = makeAuditLog()
        let client = LocalTTSClient(
            speechSynthesizer: synthesizer,
            playbackCompletionGraceInterval: 0.05,
            auditLog: auditLog
        )
        let submission = Task { try await client.speakText("A sentence with no finish callback.") }
        defer { client.stopPlayback() }
        try await waitForSubmission(synthesizer)
        synthesizer.start(try #require(synthesizer.utterances.first))
        try await submission.value
        synthesizer.isSpeaking = false
        try await Task.sleep(for: .milliseconds(120))
        // Inspect the audit first: reconciliation must run without a caller
        // polling isPlaying, which may itself reconcile the native state.
        #expect(auditLog.readAllEntries().contains { $0.operation == "apple_speech.reconciled_native_idle" })
        #expect(!client.isPlaying)
        #expect(synthesizer.stopCount == 0)
    }

    @Test func confirmedNativeSpeechRemainsActiveBeyondCompletionGrace() async throws {
        let synthesizer = TestSpeechSynthesizer()
        let client = LocalTTSClient(
            speechSynthesizer: synthesizer,
            playbackCompletionGraceInterval: 0.03,
            auditLog: makeAuditLog()
        )
        let submission = Task { try await client.speakText("This sentence continues speaking.") }
        defer { client.stopPlayback() }
        try await waitForSubmission(synthesizer)
        synthesizer.start(try #require(synthesizer.utterances.first))
        try await submission.value
        try await Task.sleep(for: .milliseconds(80))
        #expect(client.isPlaying)
        #expect(synthesizer.stopCount == 0)
    }

    @Test func queuedSubmissionDuringNativeIdleGraceStillGetsItsOwnStartupTimeout() async throws {
        let synthesizer = TestSpeechSynthesizer()
        let auditLog = makeAuditLog()
        let client = LocalTTSClient(
            speechSynthesizer: synthesizer,
            playbackStartTimeout: 0.03,
            playbackCompletionGraceInterval: 0.08,
            auditLog: auditLog
        )
        let firstSubmission = Task { try await client.speakText("The previous speech loses its finish callback.") }
        defer { client.stopPlayback() }
        try await waitForSubmission(synthesizer)
        synthesizer.start(try #require(synthesizer.utterances.first))
        try await firstSubmission.value
        synthesizer.isSpeaking = false
        var queuedSubmissionFinished = false
        let queuedSubmission = Task {
            defer { queuedSubmissionFinished = true }
            try await client.speakText("The queued sentence never starts.")
        }
        try await waitForSubmission(synthesizer, count: 2)
        for _ in 0..<100 {
            if queuedSubmissionFinished { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(queuedSubmissionFinished)
        if !queuedSubmissionFinished { client.stopPlayback() }
        do {
            try await queuedSubmission.value
            Issue.record("The queued sentence must fail its startup deadline.")
        } catch { #expect(error as? LocalTTSPlaybackError == .playbackDidNotStart) }
        let entries = auditLog.readAllEntries()
        #expect(entries.contains { $0.operation == "apple_speech.reconciled_native_idle" })
        #expect(entries.contains { $0.operation == "apple_speech.timeout" })
        #expect(!client.isPlaying)
    }

    @Test func directSpeechFailureCannotNotifyAnUnrelatedPipeline() async {
        let synthesizer = TestSpeechSynthesizer()
        let client = LocalTTSClient(speechSynthesizer: synthesizer, playbackStartTimeout: 0.02, auditLog: makeAuditLog())
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: client)
        var failureNoticeCount = 0
        pipeline.onPlaybackFailure = { failureNoticeCount += 1 }
        do {
            try await client.speakText("A direct reminder with no chat answer.")
            Issue.record("The direct utterance must fail startup.")
        } catch { #expect(error as? LocalTTSPlaybackError == .playbackDidNotStart) }
        #expect(failureNoticeCount == 0)

        await pipeline.acceptStreamedText("This reply belongs to the pipeline.")
        #expect(failureNoticeCount == 1)
    }

    @Test func pipelineReportsStartupFailureOnceAndKeepsAnswerTextVisible() async {
        let synthesizer = TestSpeechSynthesizer()
        let client = LocalTTSClient(speechSynthesizer: synthesizer, playbackStartTimeout: 0.02, auditLog: makeAuditLog())
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: client)
        var failureNoticeCount = 0
        pipeline.onPlaybackFailure = { failureNoticeCount += 1 }

        await pipeline.acceptStreamedText("The answer remains visible in chat.")
        #expect(failureNoticeCount == 1)
        #expect(pipeline.firstSpokenWordCharacterCount == 0)
        #expect(pipeline.inFlightStreamedText == "The answer remains visible in chat.")
        await pipeline.flushFinal(finalSpokenText: "The answer remains visible in chat.")
        #expect(synthesizer.utterances.count == 1)
        #expect(failureNoticeCount == 1)
    }

    @Test func callerStopsPendingSpeechBeforeResettingForFreshResponse() async throws {
        let synthesizer = TestSpeechSynthesizer()
        let client = LocalTTSClient(speechSynthesizer: synthesizer, auditLog: makeAuditLog())
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: client)
        var failureNoticeCount = 0
        pipeline.onPlaybackFailure = { failureNoticeCount += 1 }
        let submission = Task { await pipeline.acceptStreamedText("The old turn is waiting to start.") }
        try await waitForSubmission(synthesizer)
        client.stopPlayback()
        pipeline.resetForNewTurn()
        await submission.value
        #expect(!client.isPlaying)
        #expect(synthesizer.stopCount == 1)
        #expect(pipeline.firstSpokenWordCharacterCount == 0)
        #expect(failureNoticeCount == 0)
    }

    @Test func resettingPipelineDoesNotInterruptUnrelatedDirectSpeech() async throws {
        let synthesizer = TestSpeechSynthesizer()
        let client = LocalTTSClient(speechSynthesizer: synthesizer, auditLog: makeAuditLog())
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: client)
        let submission = Task { try await client.speakText("An existing reminder is speaking.") }
        try await waitForSubmission(synthesizer)
        synthesizer.start(synthesizer.utterances[0])
        try await submission.value

        pipeline.resetForNewTurn()

        #expect(client.isPlaying)
        #expect(synthesizer.stopCount == 0)
        client.stopPlayback()
    }

    @Test func cancellingPendingSubmissionStopsItsQueue() async throws {
        let synthesizer = TestSpeechSynthesizer()
        let client = LocalTTSClient(speechSynthesizer: synthesizer, auditLog: makeAuditLog())
        let submission = Task { try await client.speakText("Cancelled before starting.") }
        try await waitForSubmission(synthesizer)
        submission.cancel()
        do {
            try await submission.value
            Issue.record("Cancelled startup must throw.")
        } catch { #expect(error is CancellationError) }
        #expect(!client.isPlaying)
        #expect(synthesizer.stopCount == 1)
    }
}

struct LocalServerTTSConfigurationTests {
    @Test func defaultsApplyWhenNothingConfigured() async throws {
        let configuration = LocalServerTTSConfiguration(
            configuredBaseURLString: nil,
            configuredModelIdentifier: nil,
            configuredVoiceIdentifier: nil,
            configuredSpeedString: nil
        )
        #expect(configuration.baseURL == LocalServerTTSConfiguration.defaultBaseURL)
        #expect(configuration.modelIdentifier == "mlx-community/Kokoro-82M-bf16")
        #expect(configuration.voiceIdentifier == "af_heart")
        #expect(configuration.speed == 1.0)
    }

    @Test func remoteBaseURLIsRefusedAndFallsBackToLoopbackDefault() async throws {
        let configuration = LocalServerTTSConfiguration(
            configuredBaseURLString: "http://192.168.1.20:8880/v1",
            configuredModelIdentifier: nil,
            configuredVoiceIdentifier: nil,
            configuredSpeedString: nil
        )
        #expect(configuration.baseURL == LocalServerTTSConfiguration.defaultBaseURL)
    }

    @Test func outOfRangeSpeedFallsBackToDefault() async throws {
        for badSpeed in ["0.1", "9", "fast", ""] {
            let configuration = LocalServerTTSConfiguration(
                configuredBaseURLString: nil,
                configuredModelIdentifier: nil,
                configuredVoiceIdentifier: nil,
                configuredSpeedString: badSpeed
            )
            #expect(configuration.speed == 1.0, "expected default speed for \(badSpeed)")
        }
    }

    @Test func speechRequestCarriesAllFields() async throws {
        let configuration = LocalServerTTSConfiguration(
            configuredBaseURLString: "http://localhost:9999/v1",
            configuredModelIdentifier: "kokoro",
            configuredVoiceIdentifier: "af_bella",
            configuredSpeedString: "1.2"
        )
        let request = configuration.speechRequest(for: "hello pace")
        #expect(request.url?.absoluteString == "http://localhost:9999/v1/audio/speech")
        #expect(request.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(
            with: try #require(request.httpBody)
        ) as? [String: Any]
        #expect(body?["input"] as? String == "hello pace")
        #expect(body?["voice"] as? String == "af_bella")
        #expect(body?["model"] as? String == "kokoro")
        #expect(body?["response_format"] as? String == "wav")
        #expect(body?["speed"] as? Double == 1.2)
    }
}

@MainActor
struct LocalServerTTSClientIntegrationTests {
    private nonisolated static let fixtureScriptPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts")
        .appendingPathComponent("tts-fixture-server.py")
        .path

    private nonisolated static let pythonThreeExecutablePath: String? = [
        "/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    private nonisolated static var isFixtureRunnable: Bool {
        pythonThreeExecutablePath != nil
            && FileManager.default.fileExists(atPath: fixtureScriptPath)
    }

    @Test(.enabled(if: LocalServerTTSClientIntegrationTests.isFixtureRunnable))
    func synthesizesPlaysAndDrainsThroughFixtureServer() async throws {
        let fixturePort = 8899
        let serverProcess = Process()
        serverProcess.executableURL = URL(
            fileURLWithPath: try #require(Self.pythonThreeExecutablePath)
        )
        serverProcess.arguments = [Self.fixtureScriptPath, String(fixturePort)]
        let readinessPipe = Pipe()
        serverProcess.standardOutput = readinessPipe
        try serverProcess.run()
        defer { serverProcess.terminate() }

        // Wait for the READY line so the first request can't race the bind.
        _ = readinessPipe.fileHandleForReading.availableData

        let client = LocalServerTTSClient(
            configuration: LocalServerTTSConfiguration(
                configuredBaseURLString: "http://127.0.0.1:\(fixturePort)/v1",
                configuredModelIdentifier: nil,
                configuredVoiceIdentifier: nil,
                configuredSpeedString: nil
            )
        )

        try await client.speakText("hello pace")
        #expect(client.isPlaying)

        // Silent fixture WAV is 0.15s — drain should finish well within 5s.
        var drainedWithinTimeout = false
        for _ in 0..<50 {
            if !client.isPlaying {
                drainedWithinTimeout = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(drainedWithinTimeout)
    }

    /// Silent BuddyTTSClient stub so fallback tests never speak through the
    /// test machine's speakers.
    private final class SilentRecordingTTSClient: BuddyTTSClient {
        private(set) var spokenTexts: [String] = []
        var isPlaying: Bool { false }
        private(set) var lastStopReason: PaceTTSStopReason = .naturalCompletion

        func speakText(_ text: String) async throws {
            spokenTexts.append(text)
        }

        func stopPlayback() {}

        func recordExpectedStopReason(_ reason: PaceTTSStopReason) {
            lastStopReason = reason
        }
    }

    @Test func unreachableServerUsesSystemVoiceFallback() async throws {
        let recordingFallback = SilentRecordingTTSClient()
        let client = LocalServerTTSClient(
            configuration: LocalServerTTSConfiguration(
                configuredBaseURLString: "http://127.0.0.1:59997/v1",
                configuredModelIdentifier: nil,
                configuredVoiceIdentifier: nil,
                configuredSpeedString: nil
            ),
            fallbackClient: recordingFallback
        )
        try await client.speakText("fallback check")

        // Let the drain loop run to completion.
        for _ in 0..<60 {
            if !client.isPlaying { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(recordingFallback.spokenTexts == ["fallback check"])
        #expect(!client.isPlaying)
    }
}
