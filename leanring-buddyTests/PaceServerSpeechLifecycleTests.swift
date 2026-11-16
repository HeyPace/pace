import AVFoundation
import Foundation
import Testing

@testable import Pace

@MainActor
@Suite(.serialized)
struct PaceServerSpeechLifecycleTests {
    private final class Fallback: BuddyTTSClient {
        var spokenTexts: [String] = []
        var isPlaying = false
        var lastStopReason: PaceTTSStopReason = .naturalCompletion
        var completion: CheckedContinuation<Void, Error>?
        func speakText(_ text: String) async throws { spokenTexts.append(text) }
        func speakUtterance(_ text: String, onStarted: @escaping @MainActor () -> Void) async throws {
            spokenTexts.append(text)
            isPlaying = true
            onStarted()
            try await withCheckedThrowingContinuation { completion = $0 }
            isPlaying = false
        }
        func stopPlayback() {
            isPlaying = false
            let previous = completion
            completion = nil
            previous?.resume(throwing: CancellationError())
        }
        func recordExpectedStopReason(_ reason: PaceTTSStopReason) { lastStopReason = reason }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
        throw CancellationError()
    }

    private func withFixture(_ body: (LocalServerTTSClient, Fallback) async throws -> Void) async throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/tts-fixture-server.py")
        let python = try #require(["/usr/bin/python3", "/opt/homebrew/bin/python3"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script.path, "8898"]
        let readiness = Pipe()
        process.standardOutput = readiness
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let ready = readiness.fileHandleForReading.availableData
        try #require(String(data: ready, encoding: .utf8)?.contains("READY") == true)
        let fallback = Fallback()
        let client = LocalServerTTSClient(configuration: .init(
            configuredBaseURLString: "http://127.0.0.1:8898/v1", configuredModelIdentifier: nil,
            configuredVoiceIdentifier: nil, configuredSpeedString: nil), fallbackClient: fallback)
        defer { client.stopPlayback() }
        try await body(client, fallback)
    }

    @Test func completionIsAfterActualPlaybackAndStartsExactlyOnce() async throws {
        try await withFixture { client, _ in
            var starts = 0
            let startedAt = ContinuousClock.now
            try await client.speakUtterance("lifecycle normal") { starts += 1 }
            #expect(starts == 1)
            #expect(startedAt.duration(to: .now) >= .milliseconds(100))
            #expect(!client.isPlaying)
        }
    }

    @Test func stoppingDelayedSynthesisNeverStartsLateAudioOrFallback() async throws {
        try await withFixture { client, fallback in
            var starts = 0
            let request = Task { try await client.speakUtterance("lifecycle delayed") { starts += 1 } }
            try await Task.sleep(for: .milliseconds(80))
            client.stopPlayback()
            do { try await request.value; Issue.record("A stopped synthesis must cancel.") }
            catch { #expect(error is CancellationError) }
            try await Task.sleep(for: .milliseconds(500))
            #expect(starts == 0)
            #expect(fallback.spokenTexts.isEmpty)
            #expect(!client.isPlaying)
        }
    }

    @Test func stoppingDuringRetryCannotStartTheRetryResult() async throws {
        try await withFixture { client, fallback in
            var starts = 0
            let request = Task { try await client.speakUtterance("lifecycle retry") { starts += 1 } }
            try await Task.sleep(for: .milliseconds(120))
            client.stopPlayback()
            do { try await request.value; Issue.record("A stopped retry must cancel.") }
            catch { #expect(error is CancellationError) }
            try await Task.sleep(for: .milliseconds(500))
            #expect(starts == 0)
            #expect(fallback.spokenTexts.isEmpty)
        }
    }

    @Test func stoppingFallbackCompletesWaiterAndStaleRequestCannotStopFreshOne() async throws {
        try await withFixture { client, fallback in
            var starts = 0
            let old = Task { try await client.speakUtterance("lifecycle fallback") { starts += 1 } }
            try await waitUntil { fallback.completion != nil }
            client.stopPlayback()
            do { try await old.value; Issue.record("A stopped fallback must cancel.") }
            catch { #expect(error is CancellationError) }
            #expect(starts == 1)
            #expect(!client.isPlaying)
            var freshStarts = 0
            try await client.speakUtterance("lifecycle normal") { freshStarts += 1 }
            #expect(freshStarts == 1)
            #expect(fallback.spokenTexts == ["lifecycle fallback"])
        }
    }

    @Test func stoppingInsideStartCallbackDoesNotStrandCompletion() async throws {
        try await withFixture { client, _ in
            do {
                try await client.speakUtterance("lifecycle normal") { client.stopPlayback() }
                Issue.record("Stopping at onset must cancel the utterance.")
            } catch { #expect(error is CancellationError) }
            #expect(!client.isPlaying)
        }
    }
    private func fixtureRequests() async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8898/requests")!)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func expectJapaneseRequests(_ requests: [[String: Any]], count: Int) {
        #expect(requests.count == count)
        #expect(requests.allSatisfy { $0["voice"] as? String == "jf_alpha" && $0["lang_code"] as? String == "j" })
    }

    @Test func japanesePlaybackDoesNotChangeDefaultSpeechBeforeOrAfterIt() async throws {
        try await withFixture { client, fallback in
            var starts = 0
            try await client.speakUtterance("default before") { starts += 1 }
            try await client.speakUtterance(.init(text: "こんにちは。", profile: .japaneseFemale)) { starts += 1 }
            try await client.speakUtterance("default after") { starts += 1 }
            let requests = try await fixtureRequests().filter { ["default before", "こんにちは。", "default after"].contains($0["input"] as? String ?? "") }
            #expect(requests.count == 3)
            #expect(requests.filter { $0["lang_code"] == nil }.allSatisfy { $0["voice"] as? String == "af_heart" })
            expectJapaneseRequests(requests.filter { $0["input"] as? String == "こんにちは。" }, count: 1)
            #expect(starts == 3)
            #expect(fallback.spokenTexts.isEmpty)
        }
    }

    @Test func japaneseRetryAndBothSplitHalvesKeepVoiceAndLanguage() async throws {
        try await withFixture { client, fallback in
            var starts = 0
            try await client.speakUtterance(.init(text: "profile retry", profile: .japaneseFemale)) { starts += 1 }
            let splitText = "profile split. first half has enough words to cross the retry boundary. second half completes the requested utterance with the same Japanese voice."
            try await client.speakUtterance(.init(text: splitText, profile: .japaneseFemale)) { starts += 1 }
            let requests = try await fixtureRequests().filter { ($0["input"] as? String ?? "").hasPrefix("profile") || ($0["input"] as? String ?? "").hasPrefix("second half") }
            expectJapaneseRequests(requests, count: 6)
            #expect(Set(requests.compactMap { $0["input"] as? String }).count == 4)
            #expect(starts == 2)
            #expect(fallback.spokenTexts.isEmpty)
        }
    }

    @Test func explicitJapaneseNeverFallsBackOnSynthesisDecodeOrSecondHalfFailure() async throws {
        try await withFixture { client, fallback in
            var starts = 0
            for text in ["profile synthesis failure", "profile invalid WAV",
                "profile split fail. first half has enough words to cross the retry boundary. second-half-fail completes the requested utterance with the same Japanese voice."] {
                do {
                    try await client.speakUtterance(.init(text: text, profile: .japaneseFemale)) { starts += 1 }
                    Issue.record("Explicit Japanese must fail without a system voice substitute.")
                } catch { #expect(error is PaceSpeechProfileError) }
            }
            #expect(starts == 1)
            #expect(fallback.spokenTexts.isEmpty)
            #expect(!client.isPlaying)
        }
    }

    @Test func japaneseTransportOutageDoesNotPoisonDefaultSpeech() async throws {
        try await withFixture { client, fallback in
            do {
                try await client.speakUtterance(.init(text: "profile transport failure", profile: .japaneseFemale), onStarted: {})
                Issue.record("Transport failure must fail explicit Japanese.")
            } catch { #expect(error is PaceSpeechProfileError) }
            #expect(!client.hasObservedSidecarOutage)
            var starts = 0
            try await client.speakUtterance("default succeeds after Japanese outage") { starts += 1 }
            #expect(starts == 1)
            #expect(fallback.spokenTexts.isEmpty)
            let requests = try await fixtureRequests()
            #expect(requests.contains { $0["input"] as? String == "default succeeds after Japanese outage" })
        }
    }

    @Test func defaultTransportOutageDoesNotPoisonJapaneseSpeech() async throws {
        try await withFixture { client, fallback in
            let defaultFailure = Task { try await client.speakUtterance("default transport failure", onStarted: {}) }
            try await waitUntil { fallback.completion != nil }
            let completion = fallback.completion
            fallback.completion = nil
            completion?.resume()
            try await defaultFailure.value
            var starts = 0
            try await client.speakUtterance(.init(text: "こんにちは。", profile: .japaneseFemale)) { starts += 1 }
            #expect(starts == 1)
            #expect(fallback.spokenTexts == ["default transport failure"])
            let requests = try await fixtureRequests()
            #expect(requests.contains { $0["input"] as? String == "こんにちは。" })
        }
    }

    @Test func cancellingDelayedJapaneseAndStoppingAtOnsetCannotStartLateOrFallback() async throws {
        try await withFixture { client, fallback in
            var starts = 0
            let delayed = Task {
                try await client.speakUtterance(.init(text: "profile delayed", profile: .japaneseFemale)) { starts += 1 }
            }
            try await Task.sleep(for: .milliseconds(80))
            delayed.cancel()
            do { try await delayed.value; Issue.record("Cancelling delayed speech must cancel completion.") }
            catch { #expect(error is CancellationError) }
            try await Task.sleep(for: .milliseconds(500))
            #expect(starts == 0)
            do {
                try await client.speakUtterance(.init(text: "こんにちは。", profile: .japaneseFemale)) {
                    starts += 1
                    client.stopPlayback()
                }
                Issue.record("Stopping Japanese at onset must cancel completion.")
            } catch { #expect(error is CancellationError) }
            #expect(starts == 1)
            #expect(fallback.spokenTexts.isEmpty)
            #expect(!client.isPlaying)
        }
    }

    @Test func nonKokoroServerRejectsExplicitProfileBeforeOnset() async {
        let fallback = Fallback()
        let client = LocalServerTTSClient(configuration: .init(configuredBaseURLString: "http://127.0.0.1:59997/v1",
            configuredModelIdentifier: "local-Qwen3-TTS", configuredVoiceIdentifier: nil, configuredSpeedString: nil), fallbackClient: fallback)
        defer { client.stopPlayback() }
        var starts = 0
        do {
            try await client.speakUtterance(.init(text: "こんにちは。", profile: .japaneseFemale)) { starts += 1 }
            Issue.record("A non-Kokoro backend cannot claim the Kokoro Japanese profile.")
        } catch { #expect(error is PaceSpeechProfileError) }
        #expect(starts == 0)
        #expect(fallback.spokenTexts.isEmpty)
        #expect(!client.isPlaying)
    }

}
