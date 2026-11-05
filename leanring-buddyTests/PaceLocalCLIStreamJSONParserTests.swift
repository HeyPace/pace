//
//  PaceLocalCLIStreamJSONParserTests.swift
//  leanring-buddyTests
//
//  Ported from CodeVetter's `cli_brain.rs` test module so the two
//  projects' parsers stay byte-compatible. Each test here mirrors a
//  Rust test in that file — if you change one parser without
//  updating the other, the corresponding assertions will diverge.
//

import Foundation
import Testing
@testable import Pace

struct PaceLocalCLIStreamJSONParserTests {

    // MARK: claude assistant + delta

    @Test func extractClaudeChunkFindsAssistantTextBlock() async throws {
        let rawLine = #"{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}"#
        let extracted = PaceLocalCLIStreamJSONParser.extractClaudeChunk(fromLine: rawLine)
        #expect(extracted == "hello")
    }

    @Test func extractClaudeChunkFindsContentBlockDelta() async throws {
        let rawLine = #"{"type":"content_block_delta","delta":{"text":"world"}}"#
        let extracted = PaceLocalCLIStreamJSONParser.extractClaudeChunk(fromLine: rawLine)
        #expect(extracted == "world")
    }

    @Test func extractClaudeChunkSkipsNonTextBlocks() async throws {
        let rawLine = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"x"}]}}"#
        let extracted = PaceLocalCLIStreamJSONParser.extractClaudeChunk(fromLine: rawLine)
        #expect(extracted == "")
    }

    @Test func extractClaudeChunkConcatenatesMultipleTextBlocks() async throws {
        // Anthropic occasionally emits multiple text blocks in one
        // assistant event (e.g. when interleaved with tool calls in
        // the same content array). Pace's port must concatenate them.
        let rawLine = #"{"type":"assistant","message":{"content":[{"type":"text","text":"foo "},{"type":"text","text":"bar"}]}}"#
        let extracted = PaceLocalCLIStreamJSONParser.extractClaudeChunk(fromLine: rawLine)
        #expect(extracted == "foo bar")
    }

    @Test func extractClaudeChunkIgnoresUnknownTypes() async throws {
        let rawLine = #"{"type":"system","message":"warming up"}"#
        let extracted = PaceLocalCLIStreamJSONParser.extractClaudeChunk(fromLine: rawLine)
        #expect(extracted == "")
    }

    @Test func extractClaudeChunkToleratesMalformedJSON() async throws {
        let extractedFromGarbage = PaceLocalCLIStreamJSONParser.extractClaudeChunk(fromLine: "not json")
        let extractedFromEmpty = PaceLocalCLIStreamJSONParser.extractClaudeChunk(fromLine: "")
        #expect(extractedFromGarbage == "")
        #expect(extractedFromEmpty == "")
    }

    // MARK: claude session_id

    @Test func extractClaudeSessionIdFromSystemInit() async throws {
        let rawLine = #"{"type":"system","subtype":"init","session_id":"abc-123","model":"sonnet"}"#
        let extracted = PaceLocalCLIStreamJSONParser.extractClaudeSessionId(fromLine: rawLine)
        #expect(extracted == "abc-123")
    }

    @Test func extractClaudeSessionIdReturnsNilWhenAbsent() async throws {
        let rawLine = #"{"type":"content_block_delta","delta":{"text":"x"}}"#
        let extracted = PaceLocalCLIStreamJSONParser.extractClaudeSessionId(fromLine: rawLine)
        #expect(extracted == nil)
    }

    @Test func extractClaudeSessionIdToleratesMalformedJSON() async throws {
        #expect(PaceLocalCLIStreamJSONParser.extractClaudeSessionId(fromLine: "not-json") == nil)
        #expect(PaceLocalCLIStreamJSONParser.extractClaudeSessionId(fromLine: "") == nil)
    }

    // MARK: codex

    @Test func extractCodexChunkPullsAgentMessage() async throws {
        let rawLine = #"{"type":"item.completed","item":{"type":"agent_message","text":"hi"}}"#
        let extracted = PaceLocalCLIStreamJSONParser.extractCodexChunk(fromLine: rawLine)
        #expect(extracted == "hi")
    }

    @Test func extractCodexChunkSkipsNonAgentMessages() async throws {
        let rawLine = #"{"type":"item.completed","item":{"type":"reasoning","text":"thinking"}}"#
        let extracted = PaceLocalCLIStreamJSONParser.extractCodexChunk(fromLine: rawLine)
        #expect(extracted == "")
    }

    @Test func extractCodexChunkIgnoresNonCompletionEvents() async throws {
        let rawLine = #"{"type":"item.started","item":{"type":"agent_message"}}"#
        let extracted = PaceLocalCLIStreamJSONParser.extractCodexChunk(fromLine: rawLine)
        #expect(extracted == "")
    }

    @Test func extractCodexChunkToleratesMalformedJSON() async throws {
        #expect(PaceLocalCLIStreamJSONParser.extractCodexChunk(fromLine: "not json") == "")
        #expect(PaceLocalCLIStreamJSONParser.extractCodexChunk(fromLine: "") == "")
    }

    // MARK: codex fixture stream (drift guard for `.cliDirect` tier)
    //
    // These pin the exact `codex exec --json` line shapes the direct-spawn
    // `.cliDirect` tier depends on, so a codex version that changes its
    // event envelope is caught by CI instead of surfacing as a silent
    // "Pace said nothing" turn.

    @Test func codexFixtureStreamAssemblesOnlyAgentMessageText() async throws {
        // A representative `codex exec --json` sequence: session/thread
        // bookkeeping, a reasoning item, then the agent message we speak.
        // Only the agent_message text must survive assembly.
        let fixtureLines = [
            #"{"type":"thread.started","thread_id":"th_abc123"}"#,
            #"{"type":"item.started","item":{"type":"agent_message"}}"#,
            #"{"type":"item.completed","item":{"type":"reasoning","text":"let me think"}}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"Opening Safari now."}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":42,"output_tokens":7}}"#
        ]
        var assembled = ""
        for line in fixtureLines {
            assembled += PaceLocalCLIStreamJSONParser.extractCodexChunk(fromLine: line)
        }
        #expect(assembled == "Opening Safari now.")
    }

    @Test func codexFixtureStreamExposesNoResumableSessionId() async throws {
        // Codex `exec --json` does not surface a claude-style session_id we
        // resume on, so the claude session-id extractor must return nil for
        // every codex line — this is why the client passes `{ _ in nil }`
        // for codex. Pinning it keeps the resume contract honest.
        let fixtureLines = [
            #"{"type":"thread.started","thread_id":"th_abc123"}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"done"}}"#
        ]
        for line in fixtureLines {
            #expect(PaceLocalCLIStreamJSONParser.extractClaudeSessionId(fromLine: line) == nil)
        }
    }

    @Test func completedTurnDeliveryHoldsItemsAndPublishesAggregateOnce() throws {
        var delivery = PaceCLITextDeliveryState(codexTextDelivery: .completedTurn)
        for line in [
            #"{"type":"thread.started","thread_id":"synthetic"}"#,
            #"{"type":"item.completed","item":{"type":"reasoning","text":"Hidden reasoning"}}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"Hello "}}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"world."}}"#,
        ] {
            #expect(delivery.consume(
                chunk: PaceLocalCLIStreamJSONParser.extractCodexChunk(fromLine: line), fromLine: line) == nil)
        }
        let completion = #"{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}"#
        #expect(delivery.consume(chunk: "", fromLine: completion) == "Hello world.")
        #expect(delivery.consume(chunk: "", fromLine: completion) == nil)
        #expect(try delivery.finishedOutput() == "Hello world.")
    }

    @Test func failedMalformedAndIncompleteTurnsNeverPublish() {
        let message = #"{"type":"item.completed","item":{"type":"agent_message","text":"Provisional"}}"#
        for trailingLines in [
            [],
            [#"{"type":"turn.failed","error":{"message":"Synthetic failure"}}"#],
            [#"{"type":"error","message":"Synthetic failure"}"#],
            [#"{"type":"turn.completed""#],
            [#"{"type":"turn.completed","error":{"message":"Synthetic failure"}}"#],
            ["not JSON", #"{"type":"turn.completed"}"#],
            [#"{"type":"turn.failed"}"#, #"{"type":"turn.completed"}"#],
        ] {
            var delivery = PaceCLITextDeliveryState(codexTextDelivery: .completedTurn)
            for line in [message] + trailingLines {
                #expect(delivery.consume(
                    chunk: PaceLocalCLIStreamJSONParser.extractCodexChunk(fromLine: line), fromLine: line) == nil)
            }
            #expect(throws: PaceLocalCLIPlannerError.self) { try delivery.finishedOutput() }
        }
    }

    @Test func completedTurnCannotBeChangedByLaterMessageItems() {
        var delivery = PaceCLITextDeliveryState(codexTextDelivery: .completedTurn)
        #expect(delivery.consume(chunk: "Accepted.", fromLine: #"{"type":"item.completed"}"#) == nil)
        #expect(delivery.consume(chunk: "", fromLine: #"{"type":"turn.completed"}"#) == "Accepted.")
        #expect(delivery.consume(chunk: "[CLICK:10,20]", fromLine: #"{"type":"item.completed"}"#) == nil)
        #expect(delivery.assembledOutput == "Accepted.")
        #expect(throws: PaceLocalCLIPlannerError.self) { try delivery.finishedOutput() }
    }

    @Test func defaultDeliveryStillPublishesEachCompletedMessage() throws {
        var delivery = PaceCLITextDeliveryState(codexTextDelivery: .completedMessage)
        #expect(delivery.consume(chunk: "First ", fromLine: "") == "First ")
        #expect(delivery.consume(chunk: "second.", fromLine: "") == "First second.")
        #expect(try delivery.finishedOutput() == "First second.")
    }

    // MARK: prompt composition

    @Test func composeInitialUserPromptIncludesHistoryWhenPresent() async throws {
        let conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [
            (userPlaceholder: "what is HTML", assistantResponse: "a markup language")
        ]
        let composed = PaceLocalCLIPlannerClient.composeInitialUserPrompt(
            conversationHistory: conversationHistory,
            userPrompt: "compare HTML and XML"
        )
        #expect(composed.contains("Previous steps:"))
        #expect(composed.contains("what is HTML"))
        #expect(composed.contains("a markup language"))
        #expect(composed.hasSuffix("compare HTML and XML"))
    }

    @Test func composeInitialUserPromptOmitsHistoryHeaderWhenEmpty() async throws {
        let composed = PaceLocalCLIPlannerClient.composeInitialUserPrompt(
            conversationHistory: [],
            userPrompt: "research MCP"
        )
        #expect(!composed.contains("Previous steps:"))
        #expect(composed.hasPrefix("User: "))
        #expect(composed.hasSuffix("research MCP"))
    }

    @Test func composeCodexPromptEmbedsSystemBlock() async throws {
        let composed = PaceLocalCLIPlannerClient.composeCodexPrompt(
            systemPrompt: "you are pace.",
            conversationHistory: [],
            userPrompt: "research MCP vs ACP"
        )
        #expect(composed.hasPrefix("System instructions: you are pace."))
        #expect(composed.contains("research MCP vs ACP"))
    }
}
