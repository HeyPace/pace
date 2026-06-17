//
//  DirectAPIUsageParsingTests.swift
//  leanring-buddyTests
//
//  Pure tests for the SSE-chunk usage parsing that feeds the
//  per-turn cost badge. Cover the three real-world payload shapes
//  Pace's Direct-API client sees:
//    - Anthropic `message_start`: usage nested under `message`
//    - OpenAI `include_usage` final chunk: usage at the top level
//    - Local-LM-Studio chunks: no usage at all
//

import Foundation
import Testing
@testable import Pace

struct DirectAPIUsageParsingTests {

    // MARK: - extractUsageDictionary

    @Test func extractFindsTopLevelOpenAIUsage() async throws {
        let payload: [String: Any] = [
            "id": "chatcmpl-xyz",
            "usage": [
                "prompt_tokens": 1234,
                "completion_tokens": 5678,
                "total_tokens": 6912
            ]
        ]
        let extracted = DirectAPIPlannerClient.extractUsageDictionary(from: payload)
        #expect(extracted?["prompt_tokens"] as? Int == 1234)
        #expect(extracted?["completion_tokens"] as? Int == 5678)
    }

    @Test func extractFindsAnthropicMessageStartNestedUsage() async throws {
        let payload: [String: Any] = [
            "type": "message_start",
            "message": [
                "id": "msg_01ABC",
                "usage": [
                    "input_tokens": 12,
                    "output_tokens": 0
                ]
            ]
        ]
        let extracted = DirectAPIPlannerClient.extractUsageDictionary(from: payload)
        #expect(extracted?["input_tokens"] as? Int == 12)
        #expect(extracted?["output_tokens"] as? Int == 0)
    }

    @Test func extractReturnsNilWhenAbsent() async throws {
        let payload: [String: Any] = [
            "choices": [["delta": ["content": "hello"]]]
        ]
        let extracted = DirectAPIPlannerClient.extractUsageDictionary(from: payload)
        #expect(extracted == nil)
    }

    // MARK: - firstIntValue

    @Test func firstIntValuePicksFirstMatchingKey() async throws {
        let usage: [String: Any] = ["input_tokens": 42, "prompt_tokens": 99]
        let resolvedInputTokens = DirectAPIPlannerClient.firstIntValue(
            in: usage,
            forKeys: ["input_tokens", "prompt_tokens"]
        )
        #expect(resolvedInputTokens == 42)
    }

    @Test func firstIntValueFallsThroughToOpenAIKey() async throws {
        // OpenAI naming wins when the Anthropic key is absent.
        let usage: [String: Any] = ["prompt_tokens": 99]
        let resolvedInputTokens = DirectAPIPlannerClient.firstIntValue(
            in: usage,
            forKeys: ["input_tokens", "prompt_tokens"]
        )
        #expect(resolvedInputTokens == 99)
    }

    @Test func firstIntValueDecodesDoubleAsInt() async throws {
        // Some JSON shapes (notably anything that round-tripped
        // through NSNumber/Double) deliver the count as Double.
        let usage: [String: Any] = ["input_tokens": Double(123)]
        let resolved = DirectAPIPlannerClient.firstIntValue(
            in: usage,
            forKeys: ["input_tokens"]
        )
        #expect(resolved == 123)
    }

    @Test func firstIntValueReturnsNilWhenNoKeyMatches() async throws {
        let usage: [String: Any] = ["something_else": 42]
        let resolved = DirectAPIPlannerClient.firstIntValue(
            in: usage,
            forKeys: ["input_tokens", "prompt_tokens"]
        )
        #expect(resolved == nil)
    }

    // MARK: - End-to-end shape check

    @Test func anthropicShapeRoundTripsBothCounts() async throws {
        // Simulates the real Anthropic streaming flow: `message_start`
        // carries `input_tokens`, a later `message_delta` carries the
        // final `output_tokens`. Pace's parser folds both into the
        // audit log so the cost badge sees both.
        let messageStartPayload: [String: Any] = [
            "type": "message_start",
            "message": ["usage": ["input_tokens": 850, "output_tokens": 0]]
        ]
        let messageDeltaPayload: [String: Any] = [
            "type": "message_delta",
            "usage": ["output_tokens": 1240]
        ]

        let startUsage = DirectAPIPlannerClient.extractUsageDictionary(from: messageStartPayload)
        let endUsage = DirectAPIPlannerClient.extractUsageDictionary(from: messageDeltaPayload)
        try #require(startUsage != nil)
        try #require(endUsage != nil)

        let inputTokens = DirectAPIPlannerClient.firstIntValue(
            in: startUsage!,
            forKeys: ["input_tokens", "prompt_tokens"]
        )
        let outputTokens = DirectAPIPlannerClient.firstIntValue(
            in: endUsage!,
            forKeys: ["output_tokens", "completion_tokens"]
        )
        #expect(inputTokens == 850)
        #expect(outputTokens == 1240)
    }
}
