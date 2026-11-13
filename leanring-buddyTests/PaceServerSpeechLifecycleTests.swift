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
}
