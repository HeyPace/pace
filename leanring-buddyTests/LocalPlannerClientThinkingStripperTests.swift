//
//  LocalPlannerClientThinkingStripperTests.swift
//  leanring-buddyTests
//
//  Tests the pure-function `<think>…</think>` stripper that defends
//  TTS and the action-tag parser from leaked reasoning text emitted
//  by thinking-mode models (Qwen3-Thinking, DeepSeek-R1-Distill, etc.).
//

import Foundation
import Testing
@testable import Pace

struct LocalPlannerClientThinkingStripperTests {

    @Test func localRequestsDisableHiddenReasoning() async throws {
        var requestBody: [String: Any] = ["model": "qwen/qwen3.5-4b"]
        PaceLocalOpenAIRequestTuning.apply(to: &requestBody)

        #expect(requestBody["reasoning_effort"] as? String == "none")
        let chatTemplateArguments = requestBody["chat_template_kwargs"] as? [String: Bool]
        #expect(chatTemplateArguments?["enable_thinking"] == false)
    }

    @Test func nativeChatURLRemovesOpenAICompatibilitySuffix() {
        let nativeChatURL = LocalPlannerClient.lmStudioNativeChatURL(
            openAICompatibleBaseURL: URL(string: "http://localhost:1234/v1")!
        )

        #expect(nativeChatURL.absoluteString == "http://localhost:1234/api/v1/chat")
    }

    @Test func nativeChatRequestDisablesReasoningAndStorage() {
        let requestBody = LocalPlannerClient.lmStudioNativeChatRequestBody(
            modelIdentifier: "qwen/qwen3.5-4b",
            systemPrompt: "Be concise.",
            conversationHistory: [
                (userPlaceholder: "Who wrote Hamlet?", assistantResponse: "William Shakespeare.")
            ],
            userPrompt: "What is the largest planet?"
        )

        #expect(requestBody["reasoning"] as? String == "off")
        #expect(requestBody["store"] as? Bool == false)
        #expect(requestBody["stream"] as? Bool == true)
        #expect((requestBody["input"] as? String)?.contains("Who wrote Hamlet?") == true)
        #expect((requestBody["input"] as? String)?.hasSuffix("Assistant:") == true)
    }

    @Test func warmupAndKeepaliveProbeCannotEnterThinkingMode() {
        let requestBody = PaceLMStudioModelLoader.nativeChatProbeRequestBody(
            modelIdentifier: "qwen/qwen3.5-4b",
            input: "ok"
        )

        #expect(requestBody["reasoning"] as? String == "off")
        #expect(requestBody["store"] as? Bool == false)
        #expect(requestBody["stream"] as? Bool == false)
        #expect(requestBody["max_output_tokens"] as? Int == 1)
    }

    @Test func nativeChatParserReturnsOnlyMessageDeltas() {
        let textDelta = LocalPlannerClient.lmStudioNativeMessageDelta(
            fromSSELine: #"data: {"type":"message.delta","content":"Jupiter"}"#
        )
        let reasoningDelta = LocalPlannerClient.lmStudioNativeMessageDelta(
            fromSSELine: #"data: {"type":"reasoning.delta","content":"hidden"}"#
        )

        #expect(textDelta == "Jupiter")
        #expect(reasoningDelta == nil)
    }

    @Test func responseWithoutThinkBlockIsUnchanged() async throws {
        let raw = "saving it now. [KEY:cmd+s]"
        let stripped = LocalPlannerClient.stripThinkingBlocks(from: raw)
        #expect(stripped == "saving it now. [KEY:cmd+s]")
    }

    @Test func singleClosedThinkBlockIsRemoved() async throws {
        let raw = "<think>user wants to save. cmd+s does it.</think>saving now. [KEY:cmd+s]"
        let stripped = LocalPlannerClient.stripThinkingBlocks(from: raw)
        #expect(stripped == "saving now. [KEY:cmd+s]")
    }

    @Test func multipleClosedThinkBlocksAreAllRemoved() async throws {
        // The function removes the think blocks in-place without inserting
        // any separator. The literal space between `</think>` and the next
        // `<think>` ends up between "hello" and "world" — one space, not two.
        let raw = "<think>step 1</think>hello <think>step 2</think>world"
        let stripped = LocalPlannerClient.stripThinkingBlocks(from: raw)
        #expect(stripped == "hello world")
    }

    @Test func unterminatedThinkAtTailDropsRemainder() async throws {
        // Mid-stream snapshot: the closing </think> hasn't arrived yet.
        // Strip everything from <think> to the end so the UI/TTS preview
        // doesn't show partial thinking text. The closing tag will be in
        // a later chunk and the next call will strip the full block.
        let raw = "saving. [KEY:cmd+s] <think>let me also note that"
        let stripped = LocalPlannerClient.stripThinkingBlocks(from: raw)
        #expect(stripped == "saving. [KEY:cmd+s]")
    }

    @Test func thinkBlockTagsAreCaseInsensitive() async throws {
        let raw = "<THINK>reasoning</THINK>real response"
        let stripped = LocalPlannerClient.stripThinkingBlocks(from: raw)
        #expect(stripped == "real response")
    }

    @Test func emptyInputReturnsEmpty() async throws {
        #expect(LocalPlannerClient.stripThinkingBlocks(from: "") == "")
    }

    @Test func surroundingContentCaseIsPreserved() async throws {
        // Verify that the case-insensitive match doesn't lowercase the
        // non-think text we want to keep.
        let raw = "<think>plan</think>Hello World [CLICK:100,200]"
        let stripped = LocalPlannerClient.stripThinkingBlocks(from: raw)
        #expect(stripped == "Hello World [CLICK:100,200]")
    }

    @Test func actionTagsInsideThinkBlockAreNotExtractedAsActions() async throws {
        // Combined with the action parser: thinking text that happens to
        // contain action-tag-looking strings must not leak through.
        let raw = "<think>I should run [CLICK:1,1] to test</think>okay. [CLICK:200,300]"
        let stripped = LocalPlannerClient.stripThinkingBlocks(from: raw)
        let parsed = PaceActionTagParser.parseActions(from: stripped)

        #expect(parsed.actions.count == 1)
        if case .click(let location) = parsed.actions.first {
            #expect(location.xInScreenshotPixels == 200)
            #expect(location.yInScreenshotPixels == 300)
        } else {
            Issue.record("Expected exactly one CLICK action with coordinates from outside the think block")
        }
    }
}
