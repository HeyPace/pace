//
//  PaceOpenAIChatMessages.swift
//  leanring-buddy
//

import Foundation

/// Builds the OpenAI chat-completions `messages` array shared by the
/// OpenAI-compatible planner clients that carry the system prompt INSIDE
/// the messages array — `LocalPlannerClient` and `DirectAPIPlannerClient`.
/// Shape: one system message, the verbatim conversation-history turn pairs
/// (user placeholder + assistant response), then the current user prompt.
///
/// Extracted so the two clients can't drift; they built this identically.
/// `CloudBridgePlannerClient` deliberately does NOT use this — the bridge
/// carries the system prompt in a dedicated `systemPrompt` field (so a
/// `--system-prompt` CLI flag can consume it natively), which is a real
/// difference in the wire contract, not duplication.
nonisolated enum PaceOpenAIChatMessages {
    static func build(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        messages.append(["role": "system", "content": systemPrompt])
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }
        messages.append(["role": "user", "content": userPrompt])
        return messages
    }
}

/// Applies latency-sensitive request options that are safe for Pace's
/// loopback OpenAI-compatible runtime. LM Studio ignores unsupported fields,
/// while Qwen thinking models honor this option and emit the user-facing
/// answer immediately instead of spending the turn budget on hidden reasoning.
nonisolated enum PaceLocalOpenAIRequestTuning {
    static func apply(to requestBody: inout [String: Any]) {
        requestBody["reasoning_effort"] = "none"
        requestBody["chat_template_kwargs"] = ["enable_thinking": false]
    }
}
