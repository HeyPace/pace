import Foundation
import Testing

@testable import Pace

@MainActor @Suite(.serialized)
struct StreamingSentenceTTSPipelineProfileOnsetTests {
    final class ControlledSpeech: BuddyTTSClient {
        var onStarted: (@MainActor () -> Void)?
        var completion: CheckedContinuation<Void, Never>?
        var isPlaying = false
        var lastStopReason: PaceTTSStopReason = .naturalCompletion
        var supportsUtteranceCompletion: Bool { true }
        func supportsSpeechProfile(_ profile: PaceSpeechProfile) -> Bool { true }
        func speakText(_ text: String) async throws {}
        func speakUtterance(_ request: PaceSpeechRequest, onStarted: @escaping @MainActor () -> Void) async throws {
            self.onStarted = onStarted
            await withCheckedContinuation { completion = $0 }
        }
        func stopPlayback() { isPlaying = false }
        func recordExpectedStopReason(_ reason: PaceTTSStopReason) { lastStopReason = reason }
    }

    @Test func confirmedOnsetMarksCharactersAndLatencyBeforeUtteranceCompletes() async throws {
        let client = ControlledSpeech()
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: client)
        pipeline.markIntentCommitted()
        pipeline.setConversationLanguageModeForCurrentTurn(.japanesePractice)
        let speech = PaceSpeechRequest(text: "こんにちは。", profile: .japaneseFemale, englishSubtitle: "Hello.")
        pipeline.setBilingualReplyForCurrentTurn(.init(speechRequest: speech, englishSubtitle: "Hello."))
        let budget = PaceLatencyBudget.shared.startTurn(trigger: .chatSubmit)
        let dispatch = Task { await pipeline.flushFinal(finalSpokenText: speech.text) }
        defer {
            dispatch.cancel()
            client.completion?.resume()
            client.completion = nil
        }
        for _ in 0..<1000 {
            if client.completion != nil { break }
            await Task.yield()
        }
        let start = try #require(client.onStarted)
        #expect(pipeline.firstSpokenWordCharacterCount == 0)
        start()
        #expect(client.completion != nil)
        #expect(pipeline.firstSpokenWordCharacterCount == speech.text.count)
        #expect(budget.timestamps[.ttsFirstDispatch] != nil)
        start()
        #expect(pipeline.firstSpokenWordCharacterCount == speech.text.count)
        let completion = client.completion
        client.completion = nil
        completion?.resume()
        await dispatch.value
        #expect(pipeline.firstSpokenWordCharacterCount == speech.text.count)
    }

    @Test func cancelledOldOnsetCannotMarkTheNextTurn() async throws {
        let client = ControlledSpeech()
        let pipeline = StreamingSentenceTTSPipeline(ttsClient: client)
        pipeline.markIntentCommitted()
        pipeline.setConversationLanguageModeForCurrentTurn(.japanesePractice)
        let speech = PaceSpeechRequest(text: "こんにちは。", profile: .japaneseFemale, englishSubtitle: "Hello.")
        pipeline.setBilingualReplyForCurrentTurn(.init(speechRequest: speech, englishSubtitle: "Hello."))
        let dispatch = Task { await pipeline.flushFinal(finalSpokenText: speech.text) }
        defer {
            dispatch.cancel()
            client.completion?.resume()
            client.completion = nil
        }
        for _ in 0..<1000 {
            if client.completion != nil { break }
            await Task.yield()
        }
        let oldStart = try #require(client.onStarted)
        dispatch.cancel()
        pipeline.stopForUserDismissal()
        pipeline.resetForNewTurn()
        pipeline.markIntentCommitted()
        let nextBudget = PaceLatencyBudget.shared.startTurn(trigger: .chatSubmit)
        oldStart()
        #expect(pipeline.firstSpokenWordCharacterCount == 0)
        #expect(nextBudget.timestamps[.ttsFirstDispatch] == nil)
        let completion = client.completion
        client.completion = nil
        completion?.resume()
        await dispatch.value
        #expect(pipeline.firstSpokenWordCharacterCount == 0)
    }
}
