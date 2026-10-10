//
//  PaceMLXPlannerClientCacheTests.swift
//  leanring-buddyTests
//
//  Local planner runtime and Hugging Face asset-cache checks.

import Foundation
import Testing

@testable import Pace

@MainActor
struct PaceMLXPlannerClientCacheTests {

    @Test func localModelHonorsSystemAndHistoryWithoutLeakingPreviousRequestWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PACE_RUN_LOCAL_NOTES"] == "1" else { return }
        let planner = PaceMLXPlannerClient(
            modelIdentifier: PaceBundledModelsSettings.plannerModelIdentifier(),
            requestsStructuredActionOutput: false
        )
        let firstResult = try await planner.generateResponseStreaming(
            images: [],
            systemPrompt: "Return ONLY a JSON object containing the saved code under the key code.",
            conversationHistory: [("Save this code: cobalt", "The saved code is cobalt.")],
            userPrompt: "Return the saved code.",
            onTextChunk: { _ in }
        )
        let firstObject = try JSONSerialization.jsonObject(with: Data(firstResult.text.utf8)) as? [String: String]
        #expect(firstObject?["code"] == "cobalt")
        let secondResult = try await planner.generateResponseStreaming(
            images: [],
            systemPrompt: "Reply with exactly the word cedar. No other text.",
            conversationHistory: [],
            userPrompt: "What is the saved code?",
            onTextChunk: { _ in }
        )
        #expect(secondResult.text.trimmingCharacters(in: .whitespacesAndNewlines) == "cedar")
    }

    @Test func runtimeAvailabilityFlagMatchesCanImport() async throws {
        // The compile-time flag this whole cache layer depends on.
        // If MLXLLM imports flip false, every cache method becomes
        // a no-op and the production code falls back to the
        // not-linked error path.
        #if canImport(MLXLLM)
            #expect(PaceMLXPlannerClient.isRuntimeAvailable == true)
        #else
            #expect(PaceMLXPlannerClient.isRuntimeAvailable == false)
        #endif
    }

    @Test func shortenedModelLabelStripsQuantizationSuffix() async throws {
        // The bf16 ↔ 4-bit toggle (Lever #4) lives on the same
        // model lineage; the display-label helper should strip
        // both quantization suffixes so the Settings UI shows
        // "Qwen3-4B" regardless of which variant the user picked.
        let bf16Label = PaceMLXPlannerClient.shortenedModelLabel(
            forIdentifier: "mlx-community/Qwen3-4B-Instruct-2507-bf16"
        )
        let fourBitLabel = PaceMLXPlannerClient.shortenedModelLabel(
            forIdentifier: "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        )
        #expect(bf16Label.contains("Qwen3-4B"))
        #expect(fourBitLabel.contains("Qwen3-4B"))
    }

    @Test func standardHuggingFaceCachePathMatchesTheCLIConvention() async throws {
        let repositoryDirectory = PaceMLXPlannerClient.standardHuggingFaceRepositoryCacheDirectory(
            modelIdentifier: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            homeDirectoryURL: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        )

        #expect(
            repositoryDirectory.path
                == "/Users/example/.cache/huggingface/hub/models--mlx-community--Qwen3-4B-Instruct-2507-4bit")
    }
}
