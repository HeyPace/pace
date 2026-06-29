//
//  PaceDualAgentPrefetchTests.swift
//  leanring-buddyTests
//
//  Tests for the dual-agent pre-fetch pipeline.
//

import Foundation
import Testing
@testable import Pace

@MainActor
@Suite(.serialized)
struct PaceDualAgentPrefetchTests {

    // MARK: - Lifecycle

    @Test
    func onPTTPress_startsVLMPrefetch() async {
        let prefetch = PaceDualAgentPrefetch.shared
        prefetch.isEnabled = true

        var vlmCalled = false
        prefetch.prefetchVLMContext = {
            vlmCalled = true
            return "element map: 3 buttons, 1 textfield"
        }
        defer { prefetch.prefetchVLMContext = nil }

        prefetch.onPTTPress()

        // Give the background task time to run.
        try? await Task.sleep(for: .milliseconds(200))

        #expect(vlmCalled == true)
        #expect(prefetch.currentResult?.vlmElementMap != nil)

        prefetch.cancel()
    }

    @Test
    func onStablePartial_triggersEpisodicAndRAG() async {
        let prefetch = PaceDualAgentPrefetch.shared
        prefetch.isEnabled = true

        var episodicQuery: String?
        var ragQuery: String?
        prefetch.prefetchEpisodicMemory = { query in
            episodicQuery = query
            return ["fact 1", "fact 2"]
        }
        prefetch.prefetchRAG = { query in
            ragQuery = query
            return ["doc 1"]
        }
        defer {
            prefetch.prefetchEpisodicMemory = nil
            prefetch.prefetchRAG = nil
        }

        prefetch.onStablePartial("what did I do yesterday")

        try? await Task.sleep(for: .milliseconds(300))

        #expect(episodicQuery == "what did I do yesterday")
        #expect(ragQuery == "what did I do yesterday")
        #expect(prefetch.currentResult?.episodicFacts.count == 2)
        #expect(prefetch.currentResult?.ragResults.count == 1)

        prefetch.cancel()
    }

    @Test
    func shortPartial_doesNotTrigger() async {
        let prefetch = PaceDualAgentPrefetch.shared
        prefetch.isEnabled = true

        var episodicCalled = false
        prefetch.prefetchEpisodicMemory = { _ in
            episodicCalled = true
            return []
        }
        defer { prefetch.prefetchEpisodicMemory = nil }

        // "hi" is only 1 word — below the 3-word minimum.
        prefetch.onStablePartial("hi")

        try? await Task.sleep(for: .milliseconds(200))

        #expect(episodicCalled == false)

        prefetch.cancel()
    }

    @Test
    func consume_returnsAndClearsResult() async {
        let prefetch = PaceDualAgentPrefetch.shared
        prefetch.isEnabled = true

        prefetch.prefetchVLMContext = { "element map" }
        defer { prefetch.prefetchVLMContext = nil }

        prefetch.onPTTPress()
        try? await Task.sleep(for: .milliseconds(200))

        let result = prefetch.consume()
        #expect(result != nil)
        #expect(result?.vlmElementMap == "element map")

        // Second consume should return nil (already consumed).
        let result2 = prefetch.consume()
        #expect(result2 == nil)
    }

    @Test
    func consume_returnsNilWhenNoResults() {
        let prefetch = PaceDualAgentPrefetch.shared
        prefetch.cancel()

        let result = prefetch.consume()
        #expect(result == nil)
    }

    @Test
    func cancel_clearsEverything() async {
        let prefetch = PaceDualAgentPrefetch.shared
        prefetch.isEnabled = true

        prefetch.prefetchVLMContext = { "element map" }
        defer { prefetch.prefetchVLMContext = nil }

        prefetch.onPTTPress()
        try? await Task.sleep(for: .milliseconds(100))

        prefetch.cancel()

        #expect(prefetch.currentResult == nil)
        #expect(prefetch.consume() == nil)
    }

    @Test
    func disabled_doesNotPrefetch() async {
        let prefetch = PaceDualAgentPrefetch.shared
        let originalEnabled = prefetch.isEnabled
        prefetch.isEnabled = false
        defer { prefetch.isEnabled = originalEnabled }

        var vlmCalled = false
        prefetch.prefetchVLMContext = {
            vlmCalled = true
            return "element map"
        }
        defer { prefetch.prefetchVLMContext = nil }

        prefetch.onPTTPress()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(vlmCalled == false)
        #expect(prefetch.currentResult == nil)
    }

    @Test
    func newPartialReplacesOldResult() async {
        let prefetch = PaceDualAgentPrefetch.shared
        prefetch.isEnabled = true

        prefetch.prefetchEpisodicMemory = { query in
            return ["fact for: \(query)"]
        }
        defer { prefetch.prefetchEpisodicMemory = nil }

        prefetch.onStablePartial("what is the weather")
        try? await Task.sleep(for: .milliseconds(200))

        let firstResult = prefetch.currentResult
        #expect(firstResult?.triggerTranscript == "what is the weather")

        prefetch.onStablePartial("what is the weather today")
        try? await Task.sleep(for: .milliseconds(200))

        let secondResult = prefetch.currentResult
        #expect(secondResult?.triggerTranscript == "what is the weather today")

        prefetch.cancel()
    }
}
